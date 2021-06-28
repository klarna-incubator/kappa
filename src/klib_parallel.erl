%%%
%%%   Copyright (c) 2021 Klarna Bank AB (publ)
%%%
%%%   Licensed under the Apache License, Version 2.0 (the "License");
%%%   you may not use this file except in compliance with the License.
%%%   You may obtain a copy of the License at
%%%
%%%       http://www.apache.org/licenses/LICENSE-2.0
%%%
%%%   Unless required by applicable law or agreed to in writing, software
%%%   distributed under the License is distributed on an "AS IS" BASIS,
%%%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%%   See the License for the specific language governing permissions and
%%%   limitations under the License.
%%%
%%% @doc Functions with parallel execution
%%%
%%% @end
%%%_* Module declaration ===============================================
-module(klib_parallel).


%%%_* Exports ==========================================================
-export([ config/4    %% sets #cfg{} custom values
        , do_while/3  %% normal do_while
        , do_while/4  %% parallel without special config
        , do_while/5  %% parallel with special config
        , filter/3    %% parallel without special config
        , filter/4    %% parallel with special config
        , foreach/3   %% parallel without special config
        , foreach/4   %% parallel with special config
        , map/3       %% parallel without special config
        , map/4       %% parallel with special config
        ]).

%%%_* Defines ==========================================================
-define('DOWHILE', do_while).
-define('FILTER',  filter).
-define('FOREACH', foreach).
-define('MAP',     map).

-define('NO_UPDATE', 'NO_UPDATE').

-ifdef(OTP_RELEASE).
-define(BIND_STACKTRACE(Var), :Var).
-define(GET_STACKTRACE(Var), ok).
-else.
-define(BIND_STACKTRACE(Var),).
-define(GET_STACKTRACE(Var), Var = erlang:get_stacktrace()).
-endif.

-type panic_fun() :: fun((any(), any()) -> any()).
-type error_fun() :: fun((any(), any(), any()) -> any()).
-record(cfg, { panic_fun     = fun(_, _) -> ok end :: panic_fun()
             , crash_fun     = fun(_, _, _) -> ok end :: error_fun()
             , fail_count    = 0     :: non_neg_integer()
             , allowed_fail  = 0     :: non_neg_integer()
             , fallback              :: undefined | fun()
             , return_result = false :: boolean()
             , function              :: undefined |
                                          ?FOREACH | ?DOWHILE | ?FILTER | ?MAP
             , chunk_size    = 1     :: pos_integer()
             , monitor               :: undefined | {pid(), reference()}
             }).

%%%_* Code =============================================================

%%------------------------------------------------------------------------------
%% API Functions
%%------------------------------------------------------------------------------
%% @doc Safe parallel foreach.
%%      Use N number of processes to evaluate Fun on List.  If a
%%      process crashes let the current working processes terminate in
%%      order not to kill a process e.g. in the middle of committing a
%%      mnesia transaction.
-spec foreach(fun((any()) -> any()), [any()], integer()) -> ok.
foreach(Fun, List, N) ->
  foreach(Fun, List, N, #cfg{}).

-spec foreach(fun((any()) -> any()), [any()], integer(), #cfg{}) -> ok.
foreach(Fun, List, N, Cfg0) ->
  Cfg1 = Cfg0#cfg{ fallback      = fun lists:foreach/2
                 , return_result = false
                 , function      = ?FOREACH
                 },
  exec_fun(Fun, undefined, List, N, Cfg1).

%%------------------------------------------------------------------------------
%% @doc Safe parallel map
%% @end
-spec map(fun((any()) -> any()), [any()], integer()) -> [any()].
map(Fun, List, N) ->
  map(Fun, List, N, #cfg{}).

-spec map(fun((any()) -> any()), [any()], integer(), #cfg{}) -> [any()].
map(Fun, List, N, Cfg0) ->
  Cfg1 = Cfg0#cfg{ fallback      = fun lists:map/2
                 , return_result = true
                 , function      = ?MAP
                 },
  exec_fun(Fun, undefined, List, N, Cfg1).

%%------------------------------------------------------------------------------
%% @doc Safe parallel filter
%% @end
-spec filter(fun((any()) -> boolean()), [any()], integer()) -> [any()].
filter(Fun, List, N) ->
  filter(Fun, List, N, #cfg{}).

-spec filter(fun((any()) -> boolean()), [any()], integer(), #cfg{}) -> [any()].
filter(Fun, List, N, Cfg0) ->
  Cfg1 = Cfg0#cfg{ fallback      = fun lists:filter/2
                 , return_result = true
                 , function      = ?FILTER
                 },
  exec_fun(Fun, undefined, List, N, Cfg1).

%%------------------------------------------------------------------------------
%% @doc A foreach that receives data from 2nd fun() instead of list
%% The second fun is an evaluation fun which will return either
%% 'false', which will stop the loop, or a tuple of which the first
%% element is the value which will be passed to the 1st fun and the
%% second element will be used as the evaluation value of the next
%% iteration. The result of the 1st fun is ignored.
%%
%% The eval fun should return {Value, NextEvalValue} where Value will
%% be used in the 1st Fun and NextEvalValue will be used as the new
%% EvalValue.  This allows the EvalFun to control its own state while
%% still providing values to Fun.
%% @end
-type exec_fun() :: fun((any()) -> any()).
-type eval_fun() :: fun((any()) -> {any(), any()}).
-spec do_while(exec_fun(), eval_fun(), any()) -> ok.
do_while(Fun, EvalFun, EvalValue0) when is_function(Fun),
                                        is_function(EvalFun) ->
  case EvalFun(EvalValue0) of
    false                -> ok;
    {Result, EvalValue1} ->
      Fun(Result),
      do_while(Fun, EvalFun, EvalValue1)
  end.

-spec do_while(exec_fun(), eval_fun(), any(), integer()) -> ok.
%% Spawn in parallel
do_while(Fun, EvalFun, EvalValue, N) ->
  do_while(Fun, EvalFun, EvalValue, N, #cfg{}).

-spec do_while(exec_fun(), eval_fun(), any(), integer(), #cfg{}) -> ok.
do_while(Fun, EvalFun, EvalValue, N, Cfg0) ->
  Cfg1 = Cfg0#cfg{ fallback      = fun do_while/3
                 , return_result = false
                 , function      = ?DOWHILE
                 , chunk_size    = 1
                 },
  exec_fun(Fun, EvalFun, EvalValue, N, Cfg1).
%%------------------------------------------------------------------------------
%% @doc Creates a configuration with a few custom values.  For each
%% crash, CrashFun is called with Pid and crash Reason.  Allow up to a
%% AllowedFail number of crashing jobs, when number is reached call
%% PanicFun on Pid and {ReasonForLastFailure, FailCnt}
%% @end
-spec config(PanicFun :: panic_fun(),
             CrashFun :: error_fun(),
             AllowedFail :: non_neg_integer(),
             ChunkSize :: pos_integer()) -> #cfg{}.
config(PanicFun, CrashFun, AllowedFail, ChunkSize)
  when is_function(PanicFun, 2), is_function(CrashFun, 3),
       is_integer(AllowedFail), is_integer(ChunkSize),
       ChunkSize > 0, AllowedFail >= 0 ->
  #cfg{ panic_fun    = PanicFun
      , crash_fun    = CrashFun
      , allowed_fail = AllowedFail
      , chunk_size   = ChunkSize
      }.

%%------------------------------------------------------------------------------
%% Internal Functions
%%------------------------------------------------------------------------------
%% N :: number of processes
-spec exec_fun(ExecFun :: exec_fun(),
               EvalFun :: eval_fun() | undefined,
               Data :: any(),
               NumProcesses :: integer(),
               Config :: #cfg{})
              -> any().
exec_fun(Fun, undefined, Data, N, Cfg)
  when is_integer(N) andalso (length(Data) >= N) andalso (N > 1) ->
  spawn_monitor_proc(Fun, undefined, Data, N, Cfg);
exec_fun(Fun, undefined, Data, N, Cfg)
  when is_integer(N) andalso (length(Data) < N) ->
  exec_fun(Fun, undefined, Data, length(Data), Cfg);
exec_fun(Fun, Fun2, Data, N, Cfg)
  when is_integer(N) andalso is_function(Fun2) andalso (N > 1) ->
  spawn_monitor_proc(Fun, Fun2, Data, N, Cfg);
exec_fun(Fun, Fun2, Data, _N, Cfg) ->
  process_in_serial(Cfg#cfg.fallback, Fun, Fun2, Data, Cfg#cfg.function).

%%------------------------------------------------------------------------------
%% @doc When it is not worth spawning processes
process_in_serial(Fallback, Fun, Fun2, Data, ?DOWHILE)       ->
  Fallback(Fun, Fun2, Data);
process_in_serial(Fallback, Fun, undefined, Data, _Function) ->
  Fallback(Fun, Data).

%%------------------------------------------------------------------------------
%% @doc Bi-directional monitor process This process is spawned to
%% avoid making the trap_exit affect calling process.  Monitors are
%% set up from both sides so that child can be notified to shutdown if
%% the calling process dies.
%% @end
spawn_monitor_proc(Fun, Fun2, Data, N, Cfg0) ->
  Parent = self(),
  SpawnFun = fun() ->
                 process_flag(trap_exit, true),
                 Ref = erlang:monitor(process, Parent),
                 Cfg1 = Cfg0#cfg{monitor={Parent, Ref}},
                 eval_fun(Fun, Fun2, Data, N, Cfg1)
             end,
  try spawn_and_wait(SpawnFun)
  catch error:{worker_died, Reason} -> exit(Reason)
  end.

%%------------------------------------------------------------------------------
%% executes 3 main phases: Pre-Process, Process and Post-Process
eval_fun(Fun, Fun2, Data0, N, Cfg) ->
  #cfg{return_result=Return, function=Function} = Cfg,
  {PreFun, Data1} = pre_process(Fun, Fun2, Data0, Return, Function),
  Result = eval_fun(PreFun, Data1, N, Cfg, [], []),
  post_process(Result, Return).

eval_fun(Fun, Data0, N, Cfg, ProcList, Results) ->
  {NewProcs, Data1} = spawn_workers(Fun, Data0, N, Cfg),
  handle_response(Fun, Data1, Cfg, NewProcs ++ ProcList, Results).

%%------------------------------------------------------------------------------
pre_process(Fun, undefined, Data, true, ?FILTER)    ->
  PreProcessFun = fun({No, Item}) ->
                      case Fun(Item) of
                        true  -> {No, Item};
                        %% see update_result/3
                        false -> ?NO_UPDATE
                      end
                  end,
  {PreProcessFun, prepare_sortable_result(Data)};
pre_process(Fun, Fun2, Data, false, ?DOWHILE)       ->
  {fun(Item) -> do_while(Fun, Fun2, Item) end, Data};
pre_process(Fun, undefined, Data, true, _Function)  ->
  {fun({No, Item}) -> {No, Fun(Item)} end, prepare_sortable_result(Data)};
pre_process(Fun, undefined, Data, false, _Function) ->
  {Fun, Data}.

%%------------------------------------------------------------------------------
%% TODO: write a more efficient sorter.
prepare_sortable_result(Data) when is_list(Data) ->
  lists:zip(lists:seq(1, length(Data)), Data).

%%------------------------------------------------------------------------------
%% TODO: allow different post processing options, like pre_process
post_process(Result, false) -> Result;
post_process(Result, true)  -> sort_result(Result).

%%------------------------------------------------------------------------------
%% TODO: write a more efficient sorter.
sort_result(Result0) when is_list(Result0) ->
  {_, Result1} = lists:unzip(lists:keysort(1, Result0)),
  Result1;
sort_result(Result)                        ->
  Result.

%%------------------------------------------------------------------------------
%% @doc Spawns specific number of processes.  Spawns N amount of
%% processes which will receive ChunkSize amount of elements from Data
%% (if it is a list). These processes will stay alive until there is
%% no more elements to send from Data, ie. the processes are
%% reused. If it was configured to allow failures, a process will be
%% respawned if it dies.
%% @end
spawn_workers(Fun, Data, N, Cfg) ->
  spawn_workers(Fun, Data, N, Cfg, self(), []).

spawn_workers(_Fun, Data, 0, _Cfg, _Parent, ProcList) ->
  {ProcList, Data};
spawn_workers(Fun, Data, N, Cfg, Parent, ProcList0)   ->
  #cfg{function=Function, chunk_size=ChunkSize, return_result=Return,
       crash_fun=CrashFun} = Cfg,
  SpawnFun = fun() -> worker(Parent, Fun, ChunkSize, Return, CrashFun) end,
  Pid = erlang:spawn_link(SpawnFun),
  {Chunk, Rest} = chunk(Data, Function, ChunkSize),
  _ = send_data(Pid, Chunk),
  ProcList1 = [Pid|ProcList0],
  spawn_workers(Fun, Rest, N-1, Cfg, Parent, ProcList1).

worker(Parent, Fun, ChunkSize, Return, CrashFun) ->
  receive
    {Parent, stop}  -> exit(normal);
    {Parent, Data0} ->
      Data1 = prepare_data(ChunkSize, Data0),
      _ = [execute_fun(CrashFun, Fun, Parent, Return, Data) || Data <- Data1],
      worker(Parent, Fun, ChunkSize, Return, CrashFun)
  end.

%%------------------------------------------------------------------------------
execute_fun(CrashFun, Fun, Parent, Return, Data) ->
  try
    maybe_send_result(Parent, Fun(Data), Return)
  catch
    Class:Reason ?BIND_STACKTRACE(Stacktrace) ->
      ?GET_STACKTRACE(Stacktrace),
      Self = self(),
      catch CrashFun(Self, {Reason, Stacktrace}, Data),
      erlang:raise(Class, {handled, Reason}, Stacktrace)
  end.

%%------------------------------------------------------------------------------
%% put data in list for execution function.
prepare_data(1, Data)          -> [Data];
prepare_data(_ChunkSize, Data) -> Data.

%%------------------------------------------------------------------------------
%% do not send back the result when the function do not return
%% results.  sending back data to the monitor process which will be
%% ignored in any case can slow down the speed of functions like
%% foreach and do_while, especially if the return value of the fun is
%% freaking huge
maybe_send_result(Parent, _Result, false) -> send_data(Parent, ok);
maybe_send_result(Parent, Result, true)   -> send_data(Parent, Result).

%%------------------------------------------------------------------------------
chunk(Data, ?DOWHILE, _Size) -> {Data, Data};
chunk([], _Function, _Size)  -> {stop, []};
chunk([H|T], _Function, 1)   -> {H, T};
chunk(List, _Function, Size) -> split(Size, List).

%% This split function does not preserve order and handles when not
%% enough elements remain.
split(Size, List) -> split(Size, List, []).

split(0, List, Result)  -> {Result, List};
split(_N, [], Result)   -> {Result, []};
split(N, [H|T], Result) -> split(N-1, T, [H|Result]).

%%------------------------------------------------------------------------------
handle_response(_Fun, _Data, _Cfg, [], Results)      -> Results;
handle_response(Fun, Data, Cfg, ProcList0, Results0) ->
  #cfg{function=Function, monitor={Parent, ParentRef}} = Cfg,
  receive
    %% process stopped after receiving 'stop'
    {'EXIT', Pid, normal}                                 ->
      ProcList1 = lists:delete(Pid, ProcList0),
      handle_response(Fun, Data, Cfg, ProcList1, Results0);
    %% crashed and handled. this will restart if config allows
    {'EXIT', Pid, {{handled, Reason}, Stacktrace}}        ->
      ProcList1 = lists:delete(Pid, ProcList0),
      handle_exit({Reason, Stacktrace}, Fun, Data, Cfg, ProcList1, Results0);
    %% crashed. this will restart if config allows.
    {'EXIT', Pid, Reason}                                 ->
      ProcList1 = lists:delete(Pid, ProcList0),
      catch (Cfg#cfg.crash_fun)(Pid, Reason, data_not_available),
      handle_exit(Reason, Fun, Data, Cfg, ProcList1, Results0);
    %% do_while will iterate on its own, once done will return 1 result
    {Pid, Result} when is_pid(Pid), Function =:= ?DOWHILE ->
      _ = send_data(Pid, stop),
      Results1 = update_result(Result, Results0, Cfg#cfg.return_result),
      handle_response(Fun, Data, Cfg, ProcList0, Results1);
    %% processed 1 result, will send another if available
    {Pid, Result} when is_pid(Pid)                        ->
      Results1 = update_result(Result, Results0, Cfg#cfg.return_result),
      {Chunk, Rest} = chunk(Data, Cfg#cfg.function, Cfg#cfg.chunk_size),
      _ = send_data(Pid, Chunk),
      handle_response(Fun, Rest, Cfg, ProcList0, Results1);
    %% parent died!! all your errors are belong to us
    {'DOWN', ParentRef, _, Parent, Reason}                ->
      shutdown(ProcList0),
      exit(Reason)
  end.

%%------------------------------------------------------------------------------
%% every time a worker crashes this function will be called to check next step
handle_exit(Reason, Fun, Data, Cfg, ProcList, Results) ->
  #cfg{panic_fun=PanicFun, fail_count=FailCount0, allowed_fail=Allowed} = Cfg,
  %% fail count increases because reason is not normal
  FailCount1 = FailCount0 + 1,
  case FailCount1 > Allowed of
    true ->
      %% We died too many times; stop all workers and wait for them to shutdown
      shutdown(ProcList),
      PanicFun(self(), {Reason, FailCount1}),
      exit(Reason);
    false ->
      %% Respawn
      eval_fun(Fun, Data, 1, Cfg#cfg{fail_count=FailCount1}, ProcList, Results)
  end.

%%------------------------------------------------------------------------------
%% shutdown all workers
shutdown([])        -> ok;
shutdown(ProcList0) ->
  receive
    {'EXIT', Pid, _R}               ->
      ProcList1 = lists:delete(Pid, ProcList0),
      shutdown(ProcList1);
    {Pid, _Result} when is_pid(Pid) ->
      _ = send_data(Pid, stop),
      shutdown(ProcList0)
  end.

%%------------------------------------------------------------------------------
%% @doc Updates result set
%%
%% When the result is ?NO_UPDATE it will NOT update the result set.
%% When configured to not return results it will always return 'ok'.
%% @end
update_result(?NO_UPDATE, Results, _Return) -> Results;
update_result(Result, Results, true)        -> [Result|Results];
update_result(_Result, _Results, false)     -> ok.

%%------------------------------------------------------------------------------
%% used to send stop signal as well as data chunks
send_data(Pid, Data) ->
  Pid ! {self(), Data}.

%% =====================================================================
%% Processes
%%
%% Spawning a monitored worker process using the ref trick to avoid
%% problems when the caller has a long message queue.
%% - The monitor must be set up before the worker process begins
%%   executing the fun, so that a crash or exit will not be lost.
%%   We use spawn_monitor() for this.
%% - All receive patterns must match on the same ref for the trick to
%%   work. There may not be any other patterns. Therefore we must either
%%   send the ref to the worker to use in the reply, or use exit() to create
%%   a DOWN message with the ref.
%% - If the worker expects the ref as a message, it must monitor the caller
%%   to avoid being stuck in receive in case the caller is killed between
%%   spawning and sending the ref. Using exit() avoids this problem.
%% - The caller cannot use demonitor(..., [flush]) if the message queue can
%%   be long, because that will traverse the entire queue in the common case
%%   when the monitor has already been triggered by the worker terminating
%%   after sending the reply. This is also avoided by using exit() to return
%%   the result.
%% - Only the process that created the monitor can perform the demonitor
%%   call, otherwise the worker might demonitor before returning; however,
%%   that would leave a small window where it could get killed and leave the
%%   caller stuck waiting.
-spec spawn_and_wait(fun(() -> Result)) -> Result when Result :: any().
spawn_and_wait(Fun) ->
  {Worker, Ref} = erlang:spawn_monitor(fun () ->
                                           exit({normal, Fun()})
                                       end),
  receive
    {'DOWN', Ref, process, Worker, {normal, Result}} ->
      Result;
    {'DOWN', Ref, process, Worker, Reason} ->
      error({worker_died, Reason})
  end.
