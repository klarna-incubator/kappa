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
%%%@doc Stateless utilities to do things with erlang abstract code.
-module(abstract_code_analysis).

-export([ module_dir_map/1
        , get_beam_path/2
        , get_abstract_code/1
        , beams_in_dir/1
        , map_to_beams_in_dirs/2
        , function_from_abstract/2
        , get_module_abstract/1
        , get_core_from_abstract_code/2
        , local_call_possible/2
        , scan_for_calls/3
        , scan_for_record_fields/1
        ]
       ).

-type abstract_module() :: [erl_parse:abstract_form()]. % The abstract code
                                                %for an entire module.

-type abstract_code() :: term(). % abstract_module() or any substructure
                                                % thereof.

-type record_access_type() :: get | set | index.

-export_type([ abstract_module/0
             , record_access_type/0
             ]).

get_abstract_code(BeamFile) ->
  {ok, {_Module, [{abstract_code, {raw_abstract_v1, Abstract}}]}} =
    beam_lib:chunks(BeamFile, [abstract_code]),
  Abstract.

get_beam_path(Module, DirMap) ->
  Dir = maps:get(Module, DirMap),
  File = atom_to_list(Module) ++ code:objfile_extension(),
  filename:join(Dir, File).

module_dir_map(Directories) ->
  maps:from_list(
    lists:flatmap( fun (D) ->
                       [{M,D} || M <- beams_in_dir(D)]
                   end
                 , Directories
                 )).

%% @doc Extracts the abstract code from a module, identified with an
%% atom.
%%
%% If the module is loaded in a way that disables code:which/1, is not
%% in the code path, does not contain abstract code, or uses some
%% other format for abstract code than raw_abstract_v1, an exception
%% will be generated.
-spec get_module_abstract(Module :: atom()) ->
                             abstract_module().

get_module_abstract(Module) ->
  BeamFile = code:which(Module),
  get_abstract_code(BeamFile).


%% @doc Extracts the abstract form of a single function from the
%% abstract code of a module.
%%
%% If no function matching the given mfa is present in the abstract
%% form, an exception will be generated.
%%
%% If more than one function matching the mfa is present, an exception
%% will also be generated, but that should not happen with abstract
%% code originating from successful compilation of erlang modules.
%%
%% The module name in the mfa is not checked against the module
%% attribute in the abstract, or used in any other way.
-spec function_from_abstract(abstract_module(), mfa()) ->
                                erl_parse:abstract_form().

function_from_abstract(ModuleAbstract,
                       {_Module, WantedFunction, WantedArity}) ->
  [FunctionAbstract] =
    [Abs || Abs = {function, _Line, FoundFunction, FoundArity, _Clauses}
              <- ModuleAbstract,
            WantedFunction == FoundFunction,
            WantedArity == FoundArity],
  FunctionAbstract.

%% @doc Whether a function can be called with the local call syntax.
%%
%% That is, whether the abstract code either is the abstract code for
%% the module containing the function, or imports it.
%%
%% The actual presence of the function in the abstract code is not
%% checked, only the 'module' and 'import' attributes.
-spec local_call_possible(mfa(), abstract_module()) ->
                             boolean().

local_call_possible({CalledModule, _CalledFunction, _CalledArity},
                    [{attribute, _Line, module, CalledModule} |_]) ->
  true;
local_call_possible({CalledModule, CalledFunction, CalledArity} = CalledTuple,
                    [{attribute, _Line, import, {CalledModule, Imports}} |
                     Tail]) ->
  lists:member({CalledFunction, CalledArity}, Imports)
    orelse local_call_possible(CalledTuple, Tail);
local_call_possible(CalledTuple, [_Head | Tail]) ->
  local_call_possible(CalledTuple, Tail);
local_call_possible(_CalledTuple, []) ->
  false.

function_use_fun({SoughtModule, SoughtFunction, SoughtArity}, Local) ->
  fun
    %% remote call
    ({call, _Line1,
      {remote, _Line2,
       {atom, _Line3, FoundModule},
       {atom, _Line4, FoundFunction}},
      Params})
      when SoughtModule == FoundModule,
           SoughtFunction == FoundFunction,
           length(Params) == SoughtArity ->
      [Params];
    %% local (or imported) call
    ({call, _Line1, {atom, _Line4, FoundFunction}, Params})
      when Local,
           FoundFunction == SoughtFunction,
           length(Params) == SoughtArity ->
      [Params];
    %% remote functional object, prior to OTP-9643
    ({'fun', _Line, {function, FoundModule, FoundFunction, FoundArity}})
      when SoughtModule == FoundModule,
           SoughtFunction == FoundFunction,
           SoughtArity == FoundArity ->
      ['fun'];
    %% remote functional object, after OTP-9643
    ({'fun', _Line1,
      {function,
       {atom, _Line2, FoundModule},
       {atom, _Line3, FoundFunction},
       {integer, _Line4, FoundArity}}})
      when SoughtModule == FoundModule,
           SoughtFunction == FoundFunction,
           SoughtArity == FoundArity ->
      ['fun'];
    %% Local functional object
    ({'fun', _Line, {function, FoundFunction,FoundArity}})
      when Local,
           SoughtFunction == FoundFunction,
           SoughtArity == FoundArity ->
      ['fun'];
    (_) ->
      []
  end.

%% R#record.field
record_fields_search( {record_field, _Line1, _RecExp, RecName,
                       {atom, Line2, FieldName}}, _IsInPattern) ->
  [{RecName, FieldName, Line2, get}];
%% R#record{field = Field}
record_fields_search( {record, _Line, _RecExp, RecName, RecFields}
                    , _IsInPattern) ->
  %% IsInPattern should always be false here.
  [{RecName, FieldName, Line, set} ||
    {FieldName, Line} <- scan_rec_for_fields(RecFields)];
%% #record{field = Field}
record_fields_search({record, _Line, RecName, RecFields}, IsInPattern) ->
  AccessType = record_access_type_from_pattern_status(IsInPattern),
  [{RecName, FieldName, Line, AccessType} ||
    {FieldName, Line} <- scan_rec_for_fields(RecFields)];
%% #record.field
record_fields_search({record_index, _Line1, RecName,
                      {atom, Line2, FieldName}}, _IsInPattern) ->
  [{RecName, FieldName, Line2, index}];
record_fields_search(_, _) ->
  [].

record_access_type_from_pattern_status(true) -> get;
record_access_type_from_pattern_status(false) -> set.

scan_rec_for_fields(RecFields) ->
  lists:map(
    fun({record_field, _Line1, {atom, Line2, FieldName}, _FieldValue}) ->
        {FieldName, Line2};
       ({record_field, _Line1, {var, Line2, '_'}, _FieldValue}) ->
        {'_', Line2}
    end,
    RecFields).

-spec scan_abstract(abstract_code(), fun((abstract_code()) -> [X])) -> [X].

scan_abstract(Abstract, Fun) ->
  scan_abstract( Abstract
               , fun(X, true) -> Fun(X) end
               , fun(_, _, _) -> true end
               , true
               ).

-spec scan_abstract( abstract_code()
                   , fun((abstract_code(), C) -> [X])
                   , fun((abstract_code(), pos_integer(), C) -> C)
                   , C
                   ) ->
                       [X].

scan_abstract(Abstract, AnalysisFun, UpdateContextDataFun, ContextData) ->
  AnalysisFun(Abstract, ContextData) ++
        lists:flatmap( fun({A, NewContextData}) ->
                           scan_abstract( A
                                        , AnalysisFun
                                        , UpdateContextDataFun
                                        , NewContextData
                                        )
                       end
                     , substructures_and_new_context_data( Abstract
                                                         , UpdateContextDataFun
                                                         , ContextData
                                                         )
                     ).

substructures_and_new_context_data( Abstract
                                  , UpdateContextDataFun
                                  , ContextData
                                  ) ->
  Substructures =
    if
      is_list(Abstract) -> Abstract;
      is_tuple(Abstract) -> tuple_to_list(Abstract);
      true -> []
    end,
  SubstructuresAndNumbers =
    lists:zip(Substructures, lists:seq(1, length(Substructures))),
  [  {Substructure, UpdateContextDataFun(Abstract, Number, ContextData)}
  || {Substructure, Number} <- SubstructuresAndNumbers
  ].

update_is_pattern_context_data( {match, _Line, _LHS, _RHS}
                              , 3 % position of LHS
                              , _Old
                              ) -> true;
update_is_pattern_context_data( {clause, _Line, _Vars, _Guards, _Statements}
                              , 3 % position of Vars
                              , _Old
                              ) -> true;
update_is_pattern_context_data( {generate, _Line, _Var, _Source}
                              , 3 % position of Var
                              , _Old
                              ) -> true;
update_is_pattern_context_data(_, _, Old) -> Old.

init_is_pattern_context_data() -> false.

%% @doc Search a piece of abstract code for uses to a particular
%% function.
%%
%%Returns a list with an entry for every encountered use of the
%%function, where a fun is represented by the atom 'fun', and a call
%%is represented by the abstract expressions of the parameters of the
%%call.
%%
%% The Local parameter should be used to indicate whether the function
%% can be called without an explicit module name in the context in
%% which the abstract code belongs.
-spec scan_for_calls(abstract_code(), mfa(), boolean()) ->
                        [[erl_parse:abstract_expr()] | 'fun'].

scan_for_calls(Abstract, CalledTuple, Local) ->
  scan_abstract(Abstract, function_use_fun(CalledTuple, Local)).

%% @doc Search a piece of abstract code for uses of record fields.
-spec scan_for_record_fields(abstract_code()) ->
                                [{ RecordName :: atom()
                                 , FieldName :: atom()
                                 , Line :: integer()
                                 , AccessType :: record_access_type()
                                 }].

scan_for_record_fields(Abstract) ->
  scan_abstract( Abstract
               , fun record_fields_search/2
               , fun update_is_pattern_context_data/3
               , init_is_pattern_context_data()
               ).


%% @doc Applies Fun to every module in the listed directories,
%% passing the module name and the name of the corresponding Beam file.
-spec map_to_beams_in_dirs(
        fun((Module :: atom(), file:filename()) -> X),
        [file:filename()]) -> [X].
map_to_beams_in_dirs(Fun, Directories) ->
  DirMap = module_dir_map(Directories),
  Modules = maps:keys(DirMap),
  Procs = max(2, erlang:system_info(schedulers_online) div 2),
  klib_parallel:map(fun(M) -> Fun(M, get_beam_path(M, DirMap)) end,
                    Modules, Procs).

-spec beams_in_dir(string()) -> [module()].
beams_in_dir(Directory) ->
  {ok, FileList} = file:list_dir(Directory),
  lists:flatmap(
    fun(FileName) ->
        case filename:extension(FileName) == code:objfile_extension() of
          true ->
            [list_to_atom(filename:basename(FileName, code:objfile_extension()))
            ];
          false ->
            []
        end
    end
   , FileList
   ).

%%
%% code that used to be part of dialyzer_utils in the dialyzer app
%%

-spec get_core_from_abstract_code(abstract_module(), [compile:option()]) ->
                                     {'ok', cerl:c_module()} | 'error'.

get_core_from_abstract_code(AbstrCode, Opts) ->
  %% We do not want the parse_transforms around since we already
  %% performed them. In some cases we end up in trouble when
  %% performing them again.
  AbstrCode1 = cleanup_parse_transforms(AbstrCode),
  %% Remove parse_transforms (and other options) from compile options.
  Opts2 = cleanup_compile_options(Opts),
  try compile:noenv_forms(AbstrCode1, Opts2 ++ src_compiler_opts()) of
    {ok, _, Core} -> {ok, Core};
    _What -> error
  catch
    error:_ -> error
  end.

cleanup_parse_transforms([{attribute,_,compile,{parse_transform,_}}|Left]) ->
  cleanup_parse_transforms(Left);
cleanup_parse_transforms([Other|Left]) ->
  [Other|cleanup_parse_transforms(Left)];
cleanup_parse_transforms([]) ->
  [].

cleanup_compile_options(Opts) ->
  lists:filter(fun keep_compile_option/1, Opts).

%% Using abstract, not asm or core.
keep_compile_option(from_asm) -> false;
keep_compile_option(from_core) -> false;
%% The parse transform will already have been applied, may cause
%% problems if it is re-applied.
keep_compile_option({parse_transform, _}) -> false;
keep_compile_option(warnings_as_errors) -> false;
keep_compile_option(_) -> true.

-spec src_compiler_opts() -> [compile:option(),...].

src_compiler_opts() ->
  [no_copt, to_core, binary, return_errors,
   no_inline, strict_record_tests, strict_record_updates,
   dialyzer].
