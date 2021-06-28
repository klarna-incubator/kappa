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
%%% @doc Klarna Application Analytics
-module(kappa).

%%%_* Exports ==========================================================
-export([ collect_architecture_info/1
        , get_architecture_info/1
        , get_assets/1
        , get_assets/2
        , get_db_ownership_info/1
        , get_layer/1
        , get_mutes/0
        , get_owner/1
        , get_owners/0
        , get_ownership_info/1
        , get_properties/1
        , get_table_owner/1
        , read_architecture_info/1
        ]).

-export_type([ architecture_info/0
             , ownership_info/0
             ]).

%%%_* Includes =========================================================
-include_lib("kernel/include/file.hrl").

%%%_* Records ==========================================================
-record(arch_info, { apps_in_current_layer = []
                   , api_mods              = []
                   , externals             = []
                   , layer_info            = []
                   , mod2app               = []
                   , mod2owner             = []
                   , app2owner             = []
                   , apiless_apps          = []
                   , last_good             = []
                   , hidden                = []
                   }).

-type api_rule() :: {suffix, string()} | {prefix, string()}
                    | {dir, string()} | {behaviour, atom()} | app_name.
-type location()          :: [{atom(),term()}].
-type stacktrace()        :: [{module(), atom(), byte() | [any()], location()} |
                              {module(), atom(), byte() | [any()]}].
-type owner()             :: atom().
-type table()             :: atom().
-type asset()             :: atom().
-type application()       :: atom().
-type date_time()         :: {{_,_,_}, {_,_,_}}.
-type layer()             :: atom().
-type layer_info()        :: {layer(), [application()], [atom()]}.
-type architecture_info() :: { [{module(), application()}]
                             , [{module(), owner()}]
                             , [layer_info()]
                             , [atom()]
                             , [application()]
                             , [application()]
                             , [{application(), owner()}]
                             , [application()]
                             }.

-type ownership_info()    :: {[any()], date_time()}.
-type db_ownership_info() :: {[any()], date_time()}.

%%%_* Code =============================================================
%%%_* API --------------------------------------------------------------
%% @doc Read the KAPPA architecture file and structure the content into layers,
%% applications and apis.
-spec read_architecture_info(string()) -> architecture_info().
read_architecture_info(File) ->
  {RawArchitectureInfo, _TimeRef} = get_architecture_info(File),
  collect_architecture_info(RawArchitectureInfo).

%% @doc Given the content of the KAPPA architecture file, structure the content
%% into layers, applications and apis.
-spec collect_architecture_info(RawArchitectureInfo::[any()]) ->
                                   architecture_info().
collect_architecture_info(RawArchitectureInfo) ->
  AI = #arch_info{last_good = #arch_info{}},
  collect_architecture_info(lists:reverse(RawArchitectureInfo), AI).

%% @doc Return layer of application or a module
-spec get_layer(Name::atom()) -> undefined | {atom(), [atom()]}.

get_layer(Name) when is_atom(Name)   ->
  kappa_server:get_layer(Name).

%% @doc Return an owner id based on a given stacktrace or module.
-spec get_owner(stacktrace() |
                [module()] |
                module()) -> owner() | undefined.
get_owner([Module]) when is_atom(Module) ->
  get_owner(Module);
get_owner(Module) when is_atom(Module) ->
  kappa_server:get_owner(Module);
get_owner([]) ->
  undefined;
get_owner([{M, _F, _A} | Stacktrace]) ->
  case get_owner(M) of
    undefined -> get_owner(Stacktrace);
    Owner     -> Owner
  end;
get_owner([{M, _F, _A, _L} | Stacktrace]) ->
  case get_owner(M) of
    undefined -> get_owner(Stacktrace);
    Owner     -> Owner
  end.

%% @doc Return a list of all owners
-spec get_owners() -> [owner()].

get_owners() ->
  kappa_server:get_owners().

%% @doc Return a list of applications that have no defined API.
-spec get_mutes() -> [{owner(), application()}].

get_mutes() ->
  kappa_server:get_mutes().

%% @doc Return properties of an owner.
-spec get_properties(Owner::owner()) -> any() | undefined.

get_properties(Owner) ->
  kappa_server:get_properties(Owner).

%% @doc Return owner for table.
-spec get_table_owner(table()) -> owner().
get_table_owner(Table) ->
  kappa_server:get_table_owner(Table).

%% @doc Return a list of modules owned given an owner id.
-spec get_assets(Owner::owner()) -> [asset()].

get_assets(Owner) ->
  kappa_server:get_assets(Owner).

get_assets(Owner, Type) ->
  kappa_server:get_assets(Owner, Type).

%% @doc Read the content and last modified timestamp of the KAPPA architecture
%% file.
-spec get_architecture_info(FileName::string()) -> {[any()], date_time()}.
get_architecture_info(FileName) ->
  {_ArchitectureInfo, _TimeRef} = readfile(FileName).

%% @doc Read the content and last modified timestamp of the KAPPA ownership
%% file.
-spec get_ownership_info(FileName::string()) -> ownership_info().
get_ownership_info(FileName) ->
  {_OwnershipInfo, _TimeRef} = readfile(FileName).

%% @doc Read the content and last modified timestamp of the KAPPA
%% database table ownership file.
-spec get_db_ownership_info(FileName::string()) -> db_ownership_info().
get_db_ownership_info(FileName) ->
  {_DBOwnershipInfo, _TimeRef} = readfile(FileName).

%%%_* Internals --------------------------------------------------------

readfile(Filename) ->
  try
    {ok, FileInfo} = file:read_file_info(Filename),
    {ok, Content}  = file:consult(Filename),
    TimeRef        = FileInfo#file_info.mtime,
    {Content, TimeRef}
  catch
    error:{badmatch, {error, R}} ->
      erlang:error({R, Filename})
  end.

%% NOTE: the collection traverses the kappa.eterm file bottom-up!
collect_architecture_info([Info|Left], ArchInfo) ->
  case hd(Info) of
    {layer, _Layer} ->
      collect_architecture_info(Left, collect_layer(Info, ArchInfo));
    {application, _App} ->
      collect_architecture_info(Left, collect_app(Info, ArchInfo));
    {externals, _Externals} ->
      collect_architecture_info(Left, collect_externals(Info, ArchInfo));
    {hidden, _Hidden} ->
      collect_architecture_info(Left, collect_hidden(Info, ArchInfo))
  end;
collect_architecture_info([], ArchInfo) ->
  [] = ArchInfo#arch_info.apps_in_current_layer, %% Assert being done
  { lists:flatten(ArchInfo#arch_info.mod2app)
  , lists:flatten(ArchInfo#arch_info.mod2owner)
  , lists:reverse(ArchInfo#arch_info.layer_info)
  , lists:flatten(ArchInfo#arch_info.api_mods)
  , ArchInfo#arch_info.externals
  , ArchInfo#arch_info.apiless_apps
  , ArchInfo#arch_info.app2owner
  , ArchInfo#arch_info.hidden
  }.

collect_layer(Info, AI) ->
  {layer, Layer}           = kf(layer, Info),
  {allowed_calls, Allowed} = kf(allowed_calls, Info),
  LegalCallsAtoms          = [list_to_atom(L) || L <- Allowed],
  LayerInfo                = { list_to_atom(Layer)
                             , AI#arch_info.apps_in_current_layer
                             , LegalCallsAtoms
                             },
  AI0 = case skip_layer(Layer) of
          true ->
            AI#arch_info.last_good;
          false ->
            AI#arch_info{layer_info = [LayerInfo|AI#arch_info.layer_info]
                         , apps_in_current_layer = []}
        end,
  AI0#arch_info{last_good = AI0}.

skip_layer("Test") -> os:getenv("BUILD") =:= "release";
skip_layer(_) -> false.

collect_app(Info, AI = #arch_info{apps_in_current_layer = OldCurrent}) ->
  {application, App} = kf(application, Info),
  ok = ensure_loaded(App),
  {ok, Mods} = application:get_key(App, modules),
  {Api, ApiLess} = collect_api(App, Info, Mods),
  %% Assign 'undefined' if owner is missing
  {owner, Owner}     = kf(owner, Info, undefined),
  NewMod2App         = [{Mod, App}   || Mod <- Mods],
  NewMod2Owner       = [{Mod, Owner} || Mod <- Mods],
  NewApp2Owner       = {App, Owner},
  AI#arch_info{ api_mods              = [Api         |AI#arch_info.api_mods]
              , mod2app               = [NewMod2App  |AI#arch_info.mod2app]
              , mod2owner             = [NewMod2Owner|AI#arch_info.mod2owner]
              , app2owner             = [NewApp2Owner|AI#arch_info.app2owner]
              , apps_in_current_layer = ordsets:add_element(App, OldCurrent)
              , apiless_apps          = ApiLess ++ AI#arch_info.apiless_apps
              }.

%% @private
ensure_loaded(App) ->
  case application:load(App) of
    ok -> ok;
    {error, {already_loaded, App}} -> ok;
    Other -> Other
  end.

%% @private
collect_api(App, Info, Modules) ->
  AlwaysApi = application:get_env(kappa, always_api, []),
  {Api, ApiLess} = case kf(api, Info, undefined) of
                     {api, undefined} -> {[App], [App]};
                     {api, Def} -> {Def, []}
                   end,
  ApiFull = lists:foldl(
    fun (M, Acc) ->
      case is_always_api(App, M, AlwaysApi) of
        true  -> ordsets:add_element(M, Acc);
        false -> Acc
      end
    end,
    ordsets:from_list(Api),
    Modules),
  {ordsets:to_list(ApiFull), ApiLess}.

collect_externals([{externals, Externals}], AI) ->
  [] = AI#arch_info.externals, %% Assert no externals so far
  assert_unique(Externals, "kappa externals"),
  AI#arch_info{externals=ordsets:from_list(Externals)}.

collect_hidden([{hidden, Hidden}], AI) ->
  [] = AI#arch_info.hidden,
  assert_unique(Hidden, "hidden apps"),
  AI#arch_info{hidden=ordsets:from_list(Hidden)}.

%% @private
-spec is_always_api(atom(), atom(), [api_rule()]) -> boolean().
is_always_api(App, Mod, AlwaysApi) ->
  lists:any(fun(Rule) -> is_api(App, Mod, Rule) end, AlwaysApi).

%% @private
is_api(Api, Mod, app_name) -> Api =:= Mod;
is_api(_, Mod, {suffix, Suffix}) ->
  lists:suffix(Suffix, atom_to_list(Mod));
is_api(_, Mod, {prefix, Prefix}) ->
  lists:prefix(Prefix, atom_to_list(Mod));
is_api(_, Mod, {dir, Dir}) ->
  Beam = find_beam(Mod),
  {ok, {_, [{compile_info, Info}]}} = beam_lib:chunks(Beam, [compile_info]),
  case lists:keyfind(source, 1, Info) of
    {_, Source} ->
      Suffix = filename:join(["src", Dir, atom_to_list(Mod) ++ ".erl"]),
      lists:suffix(Suffix, Source);
    false ->
      false
  end;
is_api(_, Mod, {behaviour, Behaviour}) ->
  Beam = find_beam(Mod),
  {ok, {_, [{attributes, Info}]}} = beam_lib:chunks(Beam, [attributes]),
  case lists:keyfind(behaviour, 1, Info) of
    {_, Behaviours} ->
      lists:member(Behaviour, Behaviours);
    false ->
      false
  end.


%%%_* Helpers ----------------------------------------------------------
assert_unique(List, Error) ->
  case List -- ordsets:from_list(List) of
    []   -> ok;
    Dups -> error("Not all ~s are unique! Duplicates: ~p", [Error, Dups])
  end.

kf(Key, List) -> lists:keyfind(Key, 1, List).

kf(Key, List, Default) ->
  case kf(Key, List) of
    {Key, Value} -> {Key, Value};
    false        -> {Key, Default}
  end.

%% @private
-spec find_beam(atom()) -> string().
find_beam(Mod) ->
  case code:which(Mod) of
    non_existing -> error("No module ~p loaded.", [Mod]);
    preloaded -> error("Module ~p is pre-loaded.", [Mod]);
    cover_compiled -> error("Module ~p is cover-compiled.", [Mod]);
    Beam when is_list(Beam) -> Beam
  end.

%%%_* Tests --------------------------------------------------------------------
-include_lib("eunit/include/eunit.hrl").

-ifdef(EUNIT).
get_owner_test() ->
  application:ensure_all_started(kappa),
  ?assertEqual(undefined, get_owner([])),
  ModuleOwner = kappa_server:get_owner(?MODULE),
  ?assertEqual(ModuleOwner, get_owner(?MODULE)),
  ?assertEqual(ModuleOwner, get_owner([?MODULE])),
  Stacktrace0 = [{?MODULE, foo, [bar]}],
  ?assertEqual(ModuleOwner, get_owner(Stacktrace0)),
  Stacktrace1 = [{lists, keyfind, []}],
  ?assertEqual(undefined, get_owner(Stacktrace1)),
  Stacktrace2 = [{lists, keyfind, []}, {?MODULE, foo, [bar]}],
  ?assertEqual(ModuleOwner, get_owner(Stacktrace2)),
  L = [{file, ?FILE}, {line, ?LINE}],
  Stacktrace3 = [{lists, keyfind, [], L}, {?MODULE, foo, [bar], L}],
  ?assertEqual(ModuleOwner, get_owner(Stacktrace3)),
  Stacktrace4 = [{lists, keyfind, [], L}],
  ?assertEqual(undefined, get_owner(Stacktrace4)),
  Stacktrace5 = [{?MODULE, foo, [bar], L}],
  ?assertEqual(ModuleOwner, get_owner(Stacktrace5)).

always_api_test() ->
  ?assert(is_always_api(my_app, my_app, [app_name])),
  ?assert(is_always_api(my_app, my_other_app, [{prefix, "my"}])),
  ?assert(is_always_api(my_app, my_other_app, [{suffix, "app"}])),
  ?assert(is_always_api( my_app
                       , my_app
                       , [{prefix, "my"}, {suffix, "app"}])),
  ?assertNot(is_always_api(my_app, my_app, [])),
  ?assertNot(is_always_api(my_app, other_module, [app_name])),
  ?assertNot(is_always_api(my_app, other_module, [{prefix, "my"}])),
  ?assertNot(is_always_api( my_app
                          , other_module
                          , [{prefix, "my"}, {suffix, "app"}])),
  ok.

-endif. % EUNIT

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
