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
%% @doc Interface module to call `dependency_analysis' from command line
-module(kappa_check).

-export([main/1]).

%%%_* Code =============================================================
%%%_* Entrypoint -------------------------------------------------------
main([])   -> usage();
main(Args) ->
  case parse_options(Args) of
    {ok, {Opts, Extra}}  ->
      case check_options(Opts) of
        {ok, Options} -> execute(Options, Extra);
        {error, {_Reason, Description}} ->
          usage_fail("~s~n", [Description])
      end;
    {error, _} = Err ->
      usage_fail("~s~n", [getopt:format_error(option_specs(), Err)])
  end.

default_graph_file() -> "/tmp/graph.svg".

parse_options(Args) ->
  getopt:parse(option_specs(), Args).


execute(Opts, Extra) ->
  try check(kf(mode, Opts), Opts, Extra)
  catch
    error:{duplicate_modules_found, DupMods} ->
      fail("Duplicate modules found: ~s~n", [atoms_to_list(DupMods, ", ")]);
    error:{enoent, Filename} ->
      fail("No such file or directory: ~s~n", [Filename]);
    error:{Err, Rsn} -> fail("~p error: ~p~n", [Err, Rsn])
  end.

%% TODO This duplication is suboptimal. Have defaults and args merge.
check(summary, Opts, Extra) ->
  Defaults = [ false
             , true
             , mods
             , {false, none}
             , kf(path, Opts)
             , false
             , false
             , false
             | strip_names(Extra)],
  AllWarns    = trim(dependency_analysis:check_modules([all]    ++ Defaults)),
  APIWarns    = trim(dependency_analysis:check_modules([api]    ++ Defaults)),
  LayersWarns = trim(dependency_analysis:check_modules([layers] ++ Defaults)),
  io:format(fmt("~s ~s ~s ~s~n",
                [datetime(), APIWarns, LayersWarns, AllWarns])),
  exit_with_status();
check(_, Opts, Extra) ->
  Args = [ kf(mode, Opts)
         , kf(reverse, Opts)
         , kf(count, Opts)
         , kf(entities, Opts)
         , kf(graph, Opts)
         , kf(path, Opts)
         , kf(exclusive, Opts)
         , kf(functions, Opts)
         , kf(violations, Opts)
         | strip_names(Extra)],
  Warns = dependency_analysis:check_modules(Args),
  io:format(Warns),
  exit_with_status().

%%%_* Internals --------------------------------------------------------
%% Check options for validity and combine multiple options to single
%% options (when applicable).
%% Returns {ok, NewOptions} or {error, {Reason, Description}}.
-spec check_options([{atom(), any()}]) ->
                       {ok, [{atom(), any()}]}
                         | {error, {atom(), string()}}.
check_options(RawOptions) ->
  Check = fun(Fun, Options) ->
              case Options of
                {ok, Opts1} -> Fun(Opts1);
                {error, Rsn} -> {error, Rsn}
              end
          end,

  GraphFun =
    fun(Options) ->
        DrawGraph   = kf(graph, Options),
        GraphFile   = kf(graph_file, Options),
        GraphOption = simplify_graph(DrawGraph, GraphFile),
        {ok, kstore(graph, GraphOption, kdelete(graph_file, Options))}
    end,

  EntFun =
    fun(Options) ->
        {ok,
         kstore(entities, get_entities(Options),
                kdelete(apps, kdelete(mods, Options)))}
    end,
  lists:foldl(Check,
              {ok, RawOptions},
              [GraphFun, fun ensure_mode/1, EntFun]).

ensure_mode(Options) ->
  Mode = kf(mode, Options),
  case lists:member(Mode, [api, layers, all, summary]) of
    true  -> {ok, Options};
    false -> {error, {invalid_mode, fmt("Invalid mode: ~p", [Mode])}}
  end.

%% Determine if analysis should be on modules or applications.
get_entities(Opts) ->
  get_entities(kf(mods, Opts), kf(apps, Opts)).

get_entities(false, false) -> mods;            % none given, mods is default
get_entities(true,  false) -> mods;            % mods gven
get_entities(false, true)  -> apps;            % apps given
get_entities(true,  true)  -> apps.            % both given, use apps

%% Combine options for drawing graph and specification of target file
%% to a single tuple
-spec simplify_graph(boolean(), undefined | string()) ->
                        {boolean(), none | string()}.
simplify_graph(false, undefined) -> {false, none};
simplify_graph(true,  undefined) -> {true, default_graph_file()};
simplify_graph(_,     File)      -> {true, File}.

strip_names(Names) ->
  lists:map(fun(N) -> erlang:list_to_atom(filename:basename(N)) end, Names).

atoms_to_list(L, Sep) ->
  string:join(lists:map(fun erlang:atom_to_list/1, L), Sep).

datetime() ->
  {{Y,M,D},{H,I,S}} = erlang:localtime(),
  fmt("~4.10.0B~2.10.0B~2.10.0B~2.10.0B~2.10.0B~2.10.0B", [Y,M,D,H,I,S]).

multi(Lines) ->
  multi(0, Lines).

multi(Offset, [Line | Lines]) ->
  %% Magic number: amount that getopt indents option descriptions.
  GetOptIndent = 24,
  Indent = GetOptIndent + Offset,
  [Line] ++ lists:map(fun(L) ->
                        "\n" ++ string:left("", Indent) ++ L
                    end,
                    Lines).

option_specs() ->
  [ {mode,        undefined,undefined,{atom, mods},
     multi(["api:     report non api call violations",
            "layers:  report layer violations",
            "all:     report api and layer violations",
            multi(9,
                  ["summary: print a one line summary of all violations in",
                   "the system. Options other than -p are ignored.",
                   "The format is:",
                   "<time> <non api calls> <layer violations> <sum>"])])}
  , {apps,        $a,"apps",     {boolean, false},
     "List applications violating invariants"}
  , {mods,        $m,"mods",     {boolean, true},
     "List modules violating invariants"}
  , {exclusive,   $x,"exclusive",{boolean,false},
     multi(["Only report violations where the module is a part of",
            "the analyzed set"])}
  , {functions,   $f,"functions",{boolean, false},
     multi(["Draw graph over functions.  Use carefully.",
            "Only works with -m"])}
  , {violations,  $v,"violations",{boolean, false},
     multi(["Show only violations in graph."])}
  , {reverse,     $r,"reverse",  {boolean,false},
     "Report callers to the mod/app rather than callees"}
  , {count,       $c,"count",    {boolean,false},
     "Report only the number of warnings"}
  , {graph,       $g,"graph",    {boolean,false},
     multi(["Store a graph centered around the mods/apps.",
            "Default file path is '/tmp/graph.svg'"])}
  , {graph_file,  $G,"graph-file",    {string,undefined},
     "Store a graph centered around the mods/apps at specified location."}
  , {path,        $p,"path",     {string, ok(file:get_cwd())},
     multi(["Analyze another system rather than the current.",
            "Default is current directory"])}
  , {help,        $?,"help",     undefined,
     "Show usage screen"}
  ].

usage_args() ->
  [ option_specs()
  , filename:basename(escript:script_name())
  , "[name ...]"
  , [{"names", multi(["List of applications or modules to check.",
                        "Default is to check the whole system"])}]
  ].

usage() -> erlang:apply(getopt, usage, usage_args()).

usage_fail() -> erlang:apply(getopt, usage_fail, usage_args()).

usage_fail(Fmt, Data) -> fail(Fmt, Data, fun() -> usage_fail() end).

fail(Fmt, Data) -> fail(Fmt, Data, fun() -> ignore end).

fail(Fmt, Data, Fun) ->
  io:format(standard_error, fmt(Fmt, Data), []),
  Fun(),
  exit_with_status(1).

%%%_* Helper -----------------------------------------------------------
ok({ok, Result}) -> Result.

fmt(Format, Data) -> lists:flatten(io_lib:format(Format, Data)).

trim(S) -> re:replace(S, "\\s+", "", [global]).

kf(Key, List) ->
  case lists:keyfind(Key, 1, List) of
    {Key, Value} -> Value;
    false        -> false
  end.

kdelete(Key, List) ->
  lists:keydelete(Key, 1, List).

kstore(Key, Value, List) ->
  lists:keystore(Key, 1, List, {Key, Value}).

exit_with_status() -> exit_with_status(0).
exit_with_status(Code) ->
  init:stop(Code).

-include_lib("eunit/include/eunit.hrl").

-ifdef(TEST).

no_graph_test() ->
  test_parse_options([""], graph, {false, none}).

default_graph_test() ->
  test_parse_options(["-g"], graph, {true, default_graph_file()}).

given_graph_file_test() ->
  test_parse_options(["-G/path/to/file.svg"], graph,
                     {true, "/path/to/file.svg"}).

given_graph_file_trumps_false_test() ->
  test_parse_options(["-gfalse", "-G/path/to/file.svg"], graph,
                     {true, "/path/to/file.svg"}).

modules_default_test() ->
  test_parse_options([""], entities, mods).

modules_with_no_apps_test() ->
  %% Use modules even if forced to false when -a not given
  test_parse_options(["-mfalse"], entities, mods).

applications_test() ->
  test_parse_options(["-a", "-mfalse"], entities, apps).

modules_test() ->
  test_parse_options(["-m"], entities, mods).

applications_over_modules_test() ->
  test_parse_options(["-am"], entities, apps).

mode_summary_test() ->
  test_parse_optionstrings(["summary"], mode, summary).

mode_all_test() ->
  test_parse_optionstrings(["all"], mode, all).

mode_api_test() ->
  test_parse_optionstrings(["api"], mode, api).

mode_layers_test() ->
  test_parse_optionstrings(["layers"], mode, layers).

illegal_mode_test() ->
  {ok, {Options, _Args}} = parse_options(["unmode"]),
  {Status, {Reason, _}} = check_options(Options),
  ?assertEqual(error, Status),
  ?assertEqual(invalid_mode, Reason).

%% Test helpers
test_parse_options(OptionStrings, Option, ExpectedValue) ->
  Options = parse_options_ok(OptionStrings),
  ?assertEqual(ExpectedValue, kf(Option, Options)).

test_parse_optionstrings(OptionStrings, Option, ExpectedValue) ->
  Options = parse_optionstrings_ok(OptionStrings),
  ?assertEqual(ExpectedValue, kf(Option, Options)).

parse_options_ok(OptionStrings) ->
  %% Add valid mode to concentrate on options
  parse_optionstrings_ok(["all"| OptionStrings]).

parse_optionstrings_ok(OptionStrings) ->
  {ok, {Options, _Args}} = parse_options(OptionStrings),
  {ok, SimpleOpts} = check_options(Options),
  SimpleOpts.


-endif.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
