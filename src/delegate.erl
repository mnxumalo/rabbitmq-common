%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2017 Pivotal Software, Inc.  All rights reserved.
%%

-module(delegate).

%% delegate is an alternative way of doing remote calls. Compared to
%% the rpc module, it reduces inter-node communication. For example,
%% if a message is routed to 1,000 queues on node A and needs to be
%% propagated to nodes B and C, it would be nice to avoid doing 2,000
%% remote casts to queue processes.
%%
%% An important issue here is preserving order - we need to make sure
%% that messages from a certain channel to a certain queue take a
%% consistent route, to prevent them being reordered. In fact all
%% AMQP-ish things (such as queue declaration results and basic.get)
%% must take the same route as well, to ensure that clients see causal
%% ordering correctly. Therefore we have a rather generic mechanism
%% here rather than just a message-reflector. That's also why we pick
%% the delegate process to use based on a hash of the source pid.
%%
%% When a function is invoked using delegate:invoke/2, delegate:call/2
%% or delegate:cast/2 on a group of pids, the pids are first split
%% into local and remote ones. Remote processes are then grouped by
%% node. The function is then invoked locally and on every node (using
%% gen_server2:multi/4) as many times as there are processes on that
%% node, sequentially.
%%
%% Errors returned when executing functions on remote nodes are re-raised
%% in the caller.
%%
%% RabbitMQ starts a pool of delegate processes on boot. The size of
%% the pool is configurable, the aim is to make sure we don't have too
%% few delegates and thus limit performance on many-CPU machines.

-behaviour(gen_server2).

-export([start_link/1, start_link/2,invoke_no_result/2, invoke_no_result/3,
         invoke/2, invoke/3, monitor/2, monitor/3, demonitor/1,
         call/2, cast/2, call/3, cast/3]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {node, monitors, name}).

%%----------------------------------------------------------------------------

-export_type([monitor_ref/0]).

-type monitor_ref() :: reference() | {atom(), pid()}.
-type fun_or_mfa(A) :: fun ((pid()) -> A) | {atom(), atom(), [any()]}.

-spec start_link
        (non_neg_integer()) -> {'ok', pid()} | ignore | {'error', any()}.
-spec invoke
        ( pid(),  fun_or_mfa(A)) -> A;
        ([pid()], fun_or_mfa(A)) -> {[{pid(), A}], [{pid(), term()}]}.
-spec invoke_no_result(pid() | [pid()], fun_or_mfa(any())) -> 'ok'.
-spec monitor('process', pid()) -> monitor_ref().
-spec demonitor(monitor_ref()) -> 'true'.

-spec call
        ( pid(),  any()) -> any();
        ([pid()], any()) -> {[{pid(), any()}], [{pid(), term()}]}.
-spec cast(pid() | [pid()], any()) -> 'ok'.

%%----------------------------------------------------------------------------

-define(HIBERNATE_AFTER_MIN, 1000).
-define(DESIRED_HIBERNATE,   10000).
-define(DEFAULT_NAME,        "delegate_").

%%----------------------------------------------------------------------------

start_link(Num) ->
    start_link(?DEFAULT_NAME, Num).

start_link(Name, Num) ->
    Name1 = delegate_name(Name, Num),
    gen_server2:start_link({local, Name1}, ?MODULE, [Name1], []).

invoke(Pid, FunOrMFA) ->
    invoke(Pid, ?DEFAULT_NAME, FunOrMFA).

invoke(Pid, _Name, FunOrMFA) when is_pid(Pid) andalso node(Pid) =:= node() ->
    apply1(FunOrMFA, Pid);
invoke(Pid, Name, FunOrMFA) when is_pid(Pid) ->
    case invoke([Pid], Name, FunOrMFA) of
        {[{Pid, Result}], []} ->
            Result;
        {[], [{Pid, {Class, Reason, StackTrace}}]} ->
            erlang:raise(Class, Reason, StackTrace)
    end;

invoke([], _Name, _FunOrMFA) -> %% optimisation
    {[], []};
invoke([Pid], _Name, FunOrMFA) when node(Pid) =:= node() -> %% optimisation
    case safe_invoke(Pid, FunOrMFA) of
        {ok,    _, Result} -> {[{Pid, Result}], []};
        {error, _, Error}  -> {[], [{Pid, Error}]}
    end;
invoke(Pids, Name, FunOrMFA) when is_list(Pids) ->
    {LocalPids, Grouped} = group_pids_by_node(Pids),
    %% The use of multi_call is only safe because the timeout is
    %% infinity, and thus there is no process spawned in order to do
    %% the sending. Thus calls can't overtake preceding calls/casts.
    {Replies, BadNodes} =
        case orddict:fetch_keys(Grouped) of
            []          -> {[], []};
            RemoteNodes -> gen_server2:multi_call(
                             RemoteNodes, delegate(self(), Name, RemoteNodes),
                             {invoke, FunOrMFA, Grouped}, infinity)
        end,
    BadPids = [{Pid, {exit, {nodedown, BadNode}, []}} ||
                  BadNode <- BadNodes,
                  Pid     <- orddict:fetch(BadNode, Grouped)],
    ResultsNoNode = lists:append([safe_invoke(LocalPids, FunOrMFA) |
                                  [Results || {_Node, Results} <- Replies]]),
    lists:foldl(
      fun ({ok,    Pid, Result}, {Good, Bad}) -> {[{Pid, Result} | Good], Bad};
          ({error, Pid, Error},  {Good, Bad}) -> {Good, [{Pid, Error} | Bad]}
      end, {[], BadPids}, ResultsNoNode).

invoke_no_result(Pid, FunOrMFA) ->
    invoke_no_result(Pid, ?DEFAULT_NAME, FunOrMFA).

invoke_no_result(Pid, _Name, FunOrMFA) when is_pid(Pid) andalso node(Pid) =:= node() ->
    _ = safe_invoke(Pid, FunOrMFA), %% we don't care about any error
    ok;
invoke_no_result(Pid, Name, FunOrMFA) when is_pid(Pid) ->
    invoke_no_result([Pid], Name, FunOrMFA);

invoke_no_result([], _Name, _FunOrMFA) -> %% optimisation
    ok;
invoke_no_result([Pid], _Name, FunOrMFA) when node(Pid) =:= node() -> %% optimisation
    _ = safe_invoke(Pid, FunOrMFA), %% must not die
    ok;
invoke_no_result([Pid], Name, FunOrMFA) ->
    RemoteNode  = node(Pid),
    gen_server2:abcast([RemoteNode], delegate(self(), Name, [RemoteNode]),
                       {invoke, FunOrMFA, orddict:from_list([{RemoteNode, [Pid]}])}),
    ok;
invoke_no_result(Pids, Name, FunOrMFA) when is_list(Pids) ->
    {LocalPids, Grouped} = group_pids_by_node(Pids),
    case orddict:fetch_keys(Grouped) of
        []          -> ok;
        RemoteNodes -> gen_server2:abcast(
                         RemoteNodes, delegate(self(), Name, RemoteNodes),
                         {invoke, FunOrMFA, Grouped})
    end,
    _ = safe_invoke(LocalPids, FunOrMFA), %% must not die
    ok.

monitor(process, Pid) ->
    ?MODULE:monitor(process, Pid, ?DEFAULT_NAME).

monitor(process, Pid, _Prefix) when node(Pid) =:= node() ->
    erlang:monitor(process, Pid);
monitor(process, Pid, Prefix) ->
    Name = delegate(Pid, Prefix, [node(Pid)]),
    gen_server2:cast(Name, {monitor, self(), Pid}),
    {Name, Pid}.

demonitor(Ref) when is_reference(Ref) ->
    erlang:demonitor(Ref);
demonitor({Name, Pid}) ->
    gen_server2:cast(Name, {demonitor, self(), Pid}).

call(PidOrPids, Name, Msg) ->
    invoke(PidOrPids, Name, {gen_server2, call, [Msg, infinity]}).

call(PidOrPids, Msg) ->
    %% Performance optimization, do not refactor to call delegate:call/3
    invoke(PidOrPids, ?DEFAULT_NAME, {gen_server2, call, [Msg, infinity]}).

cast(Pid, Msg) when is_pid(Pid) andalso node(Pid) =:= node() ->
    %% Performance optimization, do not refactor to call invoke_no_result
    %% There are several exported an externally unused functions - such as
    %% invoke_no_result - that could be removed and use the code directly in
    %% the caller functions - such as cast/2. This unfold of code might seem
    %% a silly refactor, but it massively reduces the memory usage in HA
    %% queues when ack/nack are sent to the node that hosts the slave queue.
    %% For some reason, memory usage increase massively and binary references are
    %% kept around with all the internal function calls here.
    %% We'll do a deeper refactor in the master branch.
    _ = safe_invoke(Pid, {gen_server2, cast, [Msg]}), %% we don't care about any error
    ok;
cast(Pid, Msg) when is_pid(Pid) ->
    %% Performance optimization, do not refactor to call invoke_no_result
    RemoteNode  = node(Pid),
    gen_server2:abcast([RemoteNode], delegate(self(), ?DEFAULT_NAME, [RemoteNode]),
                       {invoke, {gen_server2, cast, [Msg]},
                        orddict:from_list([{RemoteNode, [Pid]}])}),
    ok;
cast(PidOrPids, Msg) ->
    invoke_no_result(PidOrPids, ?DEFAULT_NAME, {gen_server2, cast, [Msg]}).

cast(PidOrPids, Name, Msg) ->
    invoke_no_result(PidOrPids, Name, {gen_server2, cast, [Msg]}).

%%----------------------------------------------------------------------------

group_pids_by_node(Pids) ->
    LocalNode = node(),
    lists:foldl(
      fun (Pid, {Local, Remote}) when node(Pid) =:= LocalNode ->
              {[Pid | Local], Remote};
          (Pid, {Local, Remote}) ->
              {Local,
               orddict:update(
                 node(Pid), fun (List) -> [Pid | List] end, [Pid], Remote)}
      end, {[], orddict:new()}, Pids).

delegate_name(Name, Hash) ->
    list_to_atom(Name ++ integer_to_list(Hash)).

delegate(Pid, Prefix, RemoteNodes) ->
    case get(delegate) of
        undefined -> Name = delegate_name(Prefix,
                              erlang:phash2(Pid,
                                            delegate_sup:count(RemoteNodes, Prefix))),
                     put(delegate, Name),
                     Name;
        Name      -> Name
    end.

safe_invoke(Pids, FunOrMFA) when is_list(Pids) ->
    [safe_invoke(Pid, FunOrMFA) || Pid <- Pids];
safe_invoke(Pid, FunOrMFA) when is_pid(Pid) ->
    try
        {ok, Pid, apply1(FunOrMFA, Pid)}
    catch Class:Reason ->
            {error, Pid, {Class, Reason, erlang:get_stacktrace()}}
    end.

apply1({M, F, A}, Arg) -> apply(M, F, [Arg | A]);
apply1(Fun,       Arg) -> Fun(Arg).

%%----------------------------------------------------------------------------

init([Name]) ->
    {ok, #state{node = node(), monitors = dict:new(), name = Name}, hibernate,
     {backoff, ?HIBERNATE_AFTER_MIN, ?HIBERNATE_AFTER_MIN, ?DESIRED_HIBERNATE}}.

handle_call({invoke, FunOrMFA, Grouped}, _From, State = #state{node = Node}) ->
    {reply, safe_invoke(orddict:fetch(Node, Grouped), FunOrMFA), State,
     hibernate}.

handle_cast({monitor, MonitoringPid, Pid},
            State = #state{monitors = Monitors}) ->
    Monitors1 = case dict:find(Pid, Monitors) of
                    {ok, {Ref, Pids}} ->
                        Pids1 = gb_sets:add_element(MonitoringPid, Pids),
                        dict:store(Pid, {Ref, Pids1}, Monitors);
                    error ->
                        Ref = erlang:monitor(process, Pid),
                        Pids = gb_sets:singleton(MonitoringPid),
                        dict:store(Pid, {Ref, Pids}, Monitors)
                end,
    {noreply, State#state{monitors = Monitors1}, hibernate};

handle_cast({demonitor, MonitoringPid, Pid},
            State = #state{monitors = Monitors}) ->
    Monitors1 = case dict:find(Pid, Monitors) of
                    {ok, {Ref, Pids}} ->
                        Pids1 = gb_sets:del_element(MonitoringPid, Pids),
                        case gb_sets:is_empty(Pids1) of
                            true  -> erlang:demonitor(Ref),
                                     dict:erase(Pid, Monitors);
                            false -> dict:store(Pid, {Ref, Pids1}, Monitors)
                        end;
                    error ->
                        Monitors
                end,
    {noreply, State#state{monitors = Monitors1}, hibernate};

handle_cast({invoke, FunOrMFA, Grouped}, State = #state{node = Node}) ->
    _ = safe_invoke(orddict:fetch(Node, Grouped), FunOrMFA),
    {noreply, State, hibernate}.

handle_info({'DOWN', Ref, process, Pid, Info},
            State = #state{monitors = Monitors, name = Name}) ->
    {noreply,
     case dict:find(Pid, Monitors) of
         {ok, {Ref, Pids}} ->
             Msg = {'DOWN', {Name, Pid}, process, Pid, Info},
             gb_sets:fold(fun (MonitoringPid, _) -> MonitoringPid ! Msg end,
                          none, Pids),
             State#state{monitors = dict:erase(Pid, Monitors)};
         error ->
             State
     end, hibernate};

handle_info(_Info, State) ->
    {noreply, State, hibernate}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
