#!/usr/bin/env escript
%% -*- mode: erlang -*-
%%! -pz lib/getopt/ebin lib/kappa/ebin
-module(kappa_ownership).

%%%_* Code =============================================================
%%%_* Entrypoint -------------------------------------------------------
main([])   -> usage();
main(Args) ->
  case getopt:parse(option_specs(), Args) of
    {ok, {Options, []}}  -> execute(Options);
    {ok, {_, NonArgs}}   -> usage_fail("Unknown argument: ~s~n", [hd(NonArgs)]);
    {error, {Rsn, Data}} -> usage_fail("~s: ~s~n", [getopt:error_reason(Rsn), Data])
  end.

%%%_* Internals --------------------------------------------------------
execute([{module, Module}|_]) -> report(show_owner, [Module]);
execute([{layer, Name}|_])    -> report(show_layer, [Name]);
execute([summary|_])          -> report(show_summary);
execute([owners| _])          -> report(show_ownership);
execute([{team, Team}| _])    -> report(show_team, [Team]);
execute([{slack, Team}| _])   -> report(show_slack_handle, [Team]);
execute([orphans| _])         -> report(show_orphans);
execute([mutes| _])           -> report(show_mutes);
execute([help|_])             -> usage().

report(Fun) -> report(Fun, []).

report(Fun, Args) ->
  ErrorLoggerFun = fun(_, [_, _, Err]) -> erlang:throw(Err) end,
  try
    code:add_pathsz(filelib:wildcard("lib/*/ebin")),
    {ok,_} = kappa_server:start(ErrorLoggerFun),
    erlang:apply(kappa_report, Fun, Args)
  catch
    error:{badmatch,{error,{bad_return_value,{enoent,Filename}}}} ->
      fail("No such file or directory: ~s~n", [Filename]);
    error:Err:ST -> fail("Unknown error: ~p~n~p~n", [Err, ST])
  end.

option_specs() ->
  [ {module, $o,"owner",  atom,     "Find owner of given module/application"}
  , {layer,  $l,"layer",  atom,     "Find layer of application or module"}
  , {team,   $t,"team",   atom,     "Show applications owned by a team"}
  , {slack,  $k,"slack",  atom,     "Show the slack handle(s) for a team"}
  , {owners, $T,"teams",  undefined,"Show all teams and their applications"}
  , {orphans,$O,"orphans",undefined,"Show applications that lack owner"}
  , {mutes,  $m,"mutes",  undefined,"Show applications that lack api"}
  , {summary,$s,"summary",undefined,"Show summary of ownership and orphans"}
  , {help,   $?,"help",   undefined,"Show usage screen"}
  ].

usage_args() -> [option_specs(), filename:basename(escript:script_name())].

usage() -> erlang:apply(getopt, usage, usage_args()).

usage_fail() -> erlang:apply(getopt, usage_fail, usage_args()).

usage_fail(Fmt, Data) -> fail(Fmt, Data, fun usage_fail/0).

fail(Fmt, Data) -> fail(Fmt, Data, fun() -> ignore end).

fail(Fmt, Data, Fun) ->
  io:format(standard_error, Fmt, Data),
  Fun(),
  erlang:halt(1).

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
