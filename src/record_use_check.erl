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
%%% @doc Check for inappropriate use of record fields
%%%
%%% This is integrated into the make process. The expected procedure
%%% for handling an error message following the pattern of "The module
%%% batch_estore improperly accesses the field eid of the record
%%% invoice on line 594." or "The module batch_estore accesses the
%%% field eid of the record invoice in 4 places. Only 3 places
%%% allowed." is as follows:
%%%
%%% Find the relevant term in
%%% record_field_use_file. In the above examples, it
%%% will be the one matching {{invoice, eid}, List}.
%%%
%%% Look near that term, to find any documentation of what the
%%% accessors for the field are supposed to be.
%%%
%%% Find nothing useful.
%%%
%%% Look inside the list designated 'List' in the above pattern for a
%%% term matching {access_modules, ModuleList}.
%%%
%%% Look through the modules named in the module list for any
%%% accessors to the field in question that look relevant to what you
%%% are trying to do.
%%%
%%% Find nothing useful.
%%%
%%% Talk to the team that owns the record in question to find out how
%%% it is supposed to be accessed.
%%%
%%% Rewrite your code, accessing the record with the appropriate
%%% accessors.
%%%
%%%
%%% The recommended procedure for registering fields of your own
%%% records to be guarded against inappropriate access is as follows:
%%%
%%% Make sure that you have accessors that cover everything that
%%% legitimately needs to be done with the field.
%%%
%%% Make extra sure that you have accessors that cover everything that
%%% legitimately needs to be done with the field.
%%%
%%% Assemble the list of the modules in which these accessors reside.
%%%
%%% Run record_use_check:current_legacy_use({RecordName, FieldName},
%%% ModuleList, []) on a node with all test code compiled and
%%% accessible in the code path (id est, be sure to run "make myday"
%%% and "add_test_path()") (Any other value for the last argument is
%%% not part of the <i>recommended</i> procedure).
%%%
%%% Eliminate any legacy use you feel competent to eliminate, then run
%%% the same call again.
%%%
%%% Create tickets for any legacy use that you do not feel competent
%%% to eliminate.
%%%
%%% Make sure that you have accessors that cover everything that
%%% legitimately needs to be done with the field.
%%%
%%% Build the term {{RecordName, FieldName}, [{access_modules,
%%% ModuleList}, {legacy_users, List}]} where List is the final result
%%% from current_legacy_use (Or {{RecordName, FieldName},
%%% [{access_modules, ModuleList}]}, if you managed to eliminate all
%%% legacy use), and put it into `record_field_use_file'
%%% in the appropriate place in the alphabetical order.
%%%
%%% Make sure that you have accessors that cover everything that
%%% legitimately needs to be done with the field.
%%%
%%% Put documentation of what the proper accessors for the field are
%%% above the term in `record_field_use_file'.
%%%
%%% Make sure that you have accessors that cover everything that
%%% legitimately needs to be done with the field.
%%%
%%% Other configurables:
%%%
%%% A term of the form {hrl, string()} can be used to identify the hrl
%%% in which the record is defined. This will let the check ignore use
%%% of other records with the same name in modules that do not make
%%% use of that hrl. The string can include one or more directory
%%% names, any of the forms "kdb.hrl", "include/kdb.hrl",
%%% "kdb/include/kdb.hrl" or "lib/kdb/include/kdb.hrl" will work. Keep
%%% in mind, however, that things like "dev/lib/kdb/include/kdb.hrl"
%%% will not work on every valid development setup.
%%%
%%% A term of the form {excepted_access_types, [set | get | index]}
%%% can be used to limit the check to certain ways of accessing the
%%% record field. This is useful if there exists an adequate set of
%%% mutators for the field, but no getter, or vice versa. When using
%%% current_legacy_use together with this, provide the list of
%%% excepted access types as the third argument.
-module(record_use_check).

%% Primarily meant as the interface towards the check built into the
%% make process. Require the code to be checked to be both in the code
%% path of the executing node and in a directory in the provided
%% list. Requires the kappa application to be in the code path, and
%% the configuration file to be in the priv dir of that application.
-export([ gather_violations/1
        , handle_violation/1
        , is_real_violation/1
        , is_reportable_in_non_test_builds/1
        ]).

%% Primarily meant as shell commands. Will examine all code in the
%% code path, except code within the OTP directories.  Require the
%% kappa application to be in the code path, and the configuration
%% file to be in the priv dir of that application.
-export([ current_legacy_use/3
        , gather_violations/0
        ]).

%% Interface that does not depend on any particular relationship
%% between the code being checked and the executing node. Exported
%% primarily for testing.
-export([ current_legacy_use/5
        , gather_violations/3
        ]).

-type field_descriptor() :: {Record :: atom(), FieldName :: atom()}.

-type access_module_rule() :: {access_modules, [module()]}.

-type usage_count() ::
        {module(), NumberOfAccesses :: pos_integer()}.

-type usage_count_list() :: [usage_count()].

-type legacy_use_rule() :: {legacy_users, usage_count_list()}.

-type excepted_access_type_rule() ::
        {excepted_access_types, [abstract_code_analysis:record_access_type()]}.

-type hrl_rule() :: {hrl, string()}.

-type rule() ::
        access_module_rule()
      | legacy_use_rule()
      | excepted_access_type_rule()
      | hrl_rule().

%% Only the first rule of each type will be read. One
%% access_module_rule is required.
-type rule_list() :: [rule()].

-type rule_set() :: {field_descriptor(), rule_list()}.

-type usage_entry() ::
        { module()
        , Line :: pos_integer()
        , abstract_code_analysis:record_access_type()
        }.

-type usage_list() :: [usage_entry()].

%% dict(field_descriptor(), usage_list()), if dict/2 existed.
-type field_use_dict() :: dict:dict().

%% dict([[string()]], [module()]), if dict/2 existed. Each string
%% list represents the name of one file included in the module, and
%% each string is a component of the file name. The string lists are
%% reverted, for easier comparison.
-type file_use_dict() :: dict:dict().

-type get_abstract_fun() ::
        fun((module()) ->
               [erl_parse:abstract_form()]).

-record( excess_legacy_violation
       , { module :: module()
         , record :: atom()
         , field_name :: atom()
         , number :: pos_integer()
         , allowed :: pos_integer()
         }
       ).

-record( unregistered_module_violation
       , { module :: module()
         , record :: atom()
         , field_name :: atom()
         , line :: pos_integer()
         }
       ).

-record( underused_legacy_exception
       , { module :: module()
         , record :: atom()
         , field_name :: atom()
         , number :: pos_integer()
         , allowed :: pos_integer()
         }
       ).

-record( unused_legacy_exception
       , { module :: module()
         , record :: atom()
         , field_name :: atom()
         }
       ).

-type violation() ::
        #excess_legacy_violation{}
      | #unregistered_module_violation{}
      | #underused_legacy_exception{}
      | #unused_legacy_exception{}.

-type violation_list() :: [violation()].

-define(APPLICATION, kappa).

-spec gather_violations() -> violation_list().
gather_violations() ->
  gather_violations(non_otp_directories(code:get_path())).

-spec gather_violations([string()]) -> violation_list().
gather_violations(Directories) ->
  DirMap = abstract_code_analysis:module_dir_map(Directories),
  Reader = fun (Module) ->
               BeamFile = abstract_code_analysis:get_beam_path(Module, DirMap),
               abstract_code_analysis:get_abstract_code(BeamFile)
           end,
  gather_violations( maps:keys(DirMap)
                   , Reader
                   , restrictions_from_file()
                   ).

-spec gather_violations( [module()]
                       , get_abstract_fun()
                       , [rule_set()]
                       ) ->
                           violation_list().
gather_violations(Beams, GetAbstractFun, Restrictions) ->
  {_Modules, RecordFieldUse, FileUse} = data_from_beams(GetAbstractFun, Beams),
  lists:flatmap( fun(Restriction) ->
                     restriction_violations( Restriction
                                           , RecordFieldUse
                                           , FileUse
                                           )
                 end
               , Restrictions
               ).

data_from_beams(GetAbstractFun, Beams) ->
  Procs = max(2, erlang:system_info(schedulers_online) div 2),
  BeamsData = klib_parallel:map(
                fun(Module) ->
                    {Module, try_get_abstract(Module, GetAbstractFun)}
                end,
                Beams, Procs),
  lists:foldl(fun ({_, undefined}, Acc) -> Acc;
                  ({Module, Data}, Acc) -> add_module(Module, Data, Acc)
              end
             , {sets:new(), dict:new(), dict:new()}
             , BeamsData).

-spec non_otp_directories([string()]) -> [string()].
non_otp_directories(Directories) ->
  lists:filter( fun(Dir) ->
                    not lists:prefix(code:lib_dir(), Dir)
                end
              , Directories
              ).

-spec all_modules([string()]) -> [module()].
all_modules(Directories) ->
  lists:flatmap( fun abstract_code_analysis:beams_in_dir/1
               , Directories
               ).

try_get_abstract(Module, GetAbstractFun) ->
  try GetAbstractFun(Module) of
      Abstract ->
        {get_field_use(Module, Abstract), get_file_use(Module, Abstract)}
  catch _:_ ->
      %% ignore modules not compiled with abstract code
      undefined
  end.

get_field_use(Module, Abstract) ->
  Fields = abstract_code_analysis:scan_for_record_fields(Abstract),
  lists:foldl( fun({Record, FieldName, Line, AccessType}, Dict ) ->
                   dict:append( {Record, FieldName}
                              , {Module, Line, AccessType}
                              , Dict
                              )
               end
             , dict:new()
             , Fields
             ).

get_file_use(Module, Abstract) ->
  FileNames = lists:usort(
                [  lists:reverse(filename:split(FileName))
                   || {attribute, _Line, file, {FileName, _Line2}}
                        <- Abstract
                        ,  FileName =/= []
                ]),
  lists:foldl( fun(ReverseSplitFileName, Dict) ->
                   dict:append( ReverseSplitFileName
                              , Module
                              , Dict
                              )
               end
             , dict:new()
             , FileNames
             ).

add_module(Module, {FieldUseDict1, FileUseDict1},
           {Modules0, FieldUseDict0, FileUseDict0} = Acc) ->
  case sets:is_element(Module, Modules0) of
    true ->
      Acc;
    false ->
      Modules = sets:add_element(Module, Modules0),
      FieldUseDict = dict:merge(
                       fun(_Field, List1, List2) -> List1 ++ List2 end,
                       FieldUseDict1,
                       FieldUseDict0
                      ),
      FileUseDict= dict:merge(
                     fun(_ReverseSplitFilePath, List1, List2) ->
                         List1 ++ List2
                     end,
                     FileUseDict1,
                     FileUseDict0
                    ),
      {Modules, FieldUseDict, FileUseDict}
  end.

%% Used to decide whether to break the build
-spec is_real_violation(violation()) -> boolean().
is_real_violation(#unregistered_module_violation{}) -> true;
is_real_violation(#excess_legacy_violation{})       -> true;
is_real_violation(#underused_legacy_exception{})    -> true;
is_real_violation(#unused_legacy_exception{})       -> true.

%% Non-test builds will produce false positives for exceptions made
%% for uncompiled code, so we provide a way to filter out any issues
%% that could possibly be such.
-spec is_reportable_in_non_test_builds(violation()) -> boolean().
is_reportable_in_non_test_builds(#unregistered_module_violation{}) -> true;
is_reportable_in_non_test_builds(#excess_legacy_violation{})       -> true;
is_reportable_in_non_test_builds(#underused_legacy_exception{})    -> false;
is_reportable_in_non_test_builds(#unused_legacy_exception{})       -> false.

%% Intended for use from the make check.
-spec handle_violation(violation()) -> any().
handle_violation(#unregistered_module_violation{ module = Module
                                               , record = Record
                                               , field_name = FieldName
                                               , line = Line
                                               }) ->
  io:format( standard_error
           , "~nThe module ~p improperly accesses the field ~p of "
             "the record ~p on line ~p.~n"
           , [Module, FieldName, Record, Line]
           );
handle_violation(#excess_legacy_violation{ module = Module
                                         , record = Record
                                         , field_name = FieldName
                                         , number = Number
                                         , allowed = Allowed
                                         }) ->
  io:format( standard_error
           , "~nThe module ~p accesses the field ~p of the record "
             "~p in ~p places. Only ~p places allowed.~n"
           , [Module, FieldName, Record, Number, Allowed]
           );
handle_violation(#underused_legacy_exception{ module = Module
                                            , record = Record
                                            , field_name = FieldName
                                            , number = Number
                                            , allowed = Allowed
                                            }) ->
  io:format( standard_error
           , "~nThe module ~p has an exception to access the field ~p of "
             "the record ~p in ~p places, but only does so in ~p places. "
             "If possible, please take the time to update the corresponding "
             "entry in ~s. It will be a tuple of the form {~p, ~p}, it "
             "will be somewhere inside a top-level term matching the "
             "pattern \"{{~p, ~p}, _}\", and the ~p should be changed to ~p.~n"
           , [ Module
             , FieldName
             , Record
             , Allowed
             , Number
             , restriction_file_location()
             , Module
             , Allowed
             , Record
             , FieldName
             , Allowed
             , Number
             ]
           );
handle_violation(#unused_legacy_exception{ module = Module
                                         , record = Record
                                         , field_name = FieldName
                                         }) ->
  io:format( standard_error
           , "~nThe module ~p has an exception to access the field ~p of "
             "the record ~p, but does not actually do so. If possible, "
             "please take the time to remove the corresponding entry in "
             "~s. It will be a tuple matching the pattern \"{~p, X}\" "
             "where X is an integer, and it will be somewhere inside a "
             "top-level term matching the pattern \"{{~p, ~p}, _}\".~n"
           , [ Module
             , FieldName
             , Record
             , restriction_file_location()
             , Module
             , Record
             , FieldName
             ]
           ).


-spec restriction_violations(rule_set(), field_use_dict(), file_use_dict()) ->
                                violation_list().
restriction_violations( {{Record, FieldName} = Field, Rules} = RuleSet
                      , UsageDict
                      , FileUseDict
                      ) ->
  Usage =
    case dict:find(Field, UsageDict) of
      error -> [];
      {ok, Usage0} -> Usage0
    end,
  {LegacyUsage, UnregisteredModuleUsage} =
    separated_questionable_usage(Usage, Rules, FileUseDict),
  UnusedLegacyExceptions =
    find_unused_legacy_exceptions(RuleSet, LegacyUsage),
  UseInUnregisteredModulesViolations =
    lists:map( unregistered_module_violation_fun(Record, FieldName)
             , UnregisteredModuleUsage),
  LegacyUsageCounts = lists:sort(count_by_module(LegacyUsage)),
  ExcessLegacyViolations =
    lists:flatmap( legacy_deviation_fun(Record, FieldName, Rules)
                 , LegacyUsageCounts),
  UseInUnregisteredModulesViolations
    ++ ExcessLegacyViolations
    ++ UnusedLegacyExceptions.

-spec find_unused_legacy_exceptions(rule_set(), usage_list()) ->
        violation_list().
find_unused_legacy_exceptions( {{Record, FieldName}, Rules}
                             , LegacyUsage
                             ) ->
  RegisteredLegacyUsersSet =
    case lists:keyfind(legacy_users, 1, Rules) of
      false -> [];
      {legacy_users, LegacyUsageList} ->
        {LegacyModules, _} = lists:unzip(LegacyUsageList),
        ordsets:from_list(LegacyModules)
    end,
  {RealLegacyUsersRawList, _Lines, _Accesstypes} =
    lists:unzip3(LegacyUsage),
  RealLegacyUsersSet = ordsets:from_list(RealLegacyUsersRawList),
  lists:map( fun(Module) ->
                 #unused_legacy_exception{ module = Module
                                         , record = Record
                                         , field_name = FieldName
                                         }
             end
           , ordsets:from_list(ordsets:subtract( RegisteredLegacyUsersSet
                                               , RealLegacyUsersSet
                                               )
                              )
           ).

-spec unregistered_module_violation_fun( Record :: atom()
                                       , FieldName :: atom()
                                       ) ->
                                           fun((usage_entry()) ->
                                                  violation()).
unregistered_module_violation_fun(Record, FieldName) ->
  fun({Module, Line, _AccessType}) ->
      #unregistered_module_violation{ module = Module
                                    , record = Record
                                    , field_name = FieldName
                                    , line = Line
                                    }
  end.

-spec legacy_deviation_fun( Record :: atom()
                          , FieldName :: atom()
                          , rule_list()
                          ) ->
                              fun((usage_count()) ->
                                     violation_list()).
legacy_deviation_fun(Record, FieldName, Rules) ->
  LegacyUsersAndNumbers =
    case lists:keyfind(legacy_users, 1, Rules) of
      false -> [];
      {legacy_users, LegacyUserList} -> LegacyUserList
    end,
  fun({Module, Number}) ->
      {Module, Allowed} = lists:keyfind(Module, 1, LegacyUsersAndNumbers),
      if
        Number > Allowed ->
          [#excess_legacy_violation{ module = Module
                                   , record = Record
                                   , field_name = FieldName
                                   , number = Number
                                   , allowed = Allowed
                                   }];
        Number < Allowed ->
          [#underused_legacy_exception{ module = Module
                                      , record = Record
                                      , field_name = FieldName
                                      , number = Number
                                      , allowed = Allowed
                                      }];
        true -> []
      end
  end.

-spec separated_questionable_usage( usage_list()
                                  , rule_list()
                                  , file_use_dict()
                                  ) ->
                                      { LegacyUsage :: usage_list()
                                      , UnregisteredModuleUsage :: usage_list()
                                      }.
separated_questionable_usage(Usage, Rules, FileUseDict) ->
  QuestionableUsage = questionable_usage(Usage, Rules, FileUseDict),
  separate_questionable_usage(QuestionableUsage, Rules).

-spec questionable_usage( usage_list()
                        , rule_list()
                        , file_use_dict()
                        ) ->
                            usage_list().
questionable_usage(Usage, Rules, FileUseDict) ->
  {access_modules, AccessModules0} = lists:keyfind(access_modules, 1, Rules),
  AccessModules = sets:from_list(AccessModules0),
  UsesTheHrl =
    case lists:keyfind(hrl, 1, Rules) of
      %% If no hrl is specified, assume that any module that uses the
      %% record name uses the intended record.
      false -> fun(_) -> true end;
      %% If an hrl is specified, consider only the modules that
      %% actually make use of that hrl, so that other records by the
      %% same name are ignored.
      {hrl, Hrl} -> uses_hrl_fun(Hrl, FileUseDict)
    end,
  ExceptedAccessTypes =
    case lists:keyfind(excepted_access_types, 1, Rules) of
      false -> sets:new();
      {excepted_access_types, EAT} -> sets:from_list(EAT)
    end,
  lists:filter( fun({Module, _Line, AccessType}) ->
                    (not sets:is_element(Module, AccessModules))
                      andalso UsesTheHrl(Module)
                      andalso
                        (not sets:is_element(AccessType, ExceptedAccessTypes))
                end
              , Usage
              ).

-spec uses_hrl_fun(string(), file_use_dict()) -> fun((module()) -> boolean()).
uses_hrl_fun(Hrl, FileUseDict) ->
  ReverseSplitHrl = lists:reverse(filename:split(Hrl)),
  ModuleLists =
    [  dict:fetch(ReverseSplitFileName, FileUseDict)
    || ReverseSplitFileName  <- dict:fetch_keys(FileUseDict)
    ,  lists:prefix( ReverseSplitHrl, ReverseSplitFileName)
    ],
  Modules = sets:from_list(lists:append(ModuleLists)),
  fun(Module) ->
      sets:is_element(Module, Modules)
  end.


-spec separate_questionable_usage( usage_list()
                                 , rule_list()
                                 ) ->
                                     { LegacyUsage :: usage_list()
                                     , UnregisteredModuleUsage :: usage_list()
                                     }.
separate_questionable_usage(QuestionableUsage, Rules) ->
  LegacyUsers =
    case lists:keyfind(legacy_users, 1, Rules) of
      false -> sets:new();
      {legacy_users, LegacyUsageList} ->
        {LegacyModules, _} = lists:unzip(LegacyUsageList),
        sets:from_list(LegacyModules)
    end,
  {LegacyUsage, UnregisteredModuleUsage} =
    lists:partition( fun({Module, _Line, _Accesstype}) ->
                         sets:is_element(Module, LegacyUsers)
                     end
                   , QuestionableUsage
                   ),
  {LegacyUsage, UnregisteredModuleUsage}.

%% For use when adding a new record field to the eterm
%%
%% Meant to be called from a node with the test code compiled and
%% test path added to its code path.
-spec current_legacy_use( field_descriptor()
                        , [module()]
                        , [abstract_code_analysis:record_access_type()]
                        ) ->
                            usage_count_list().
current_legacy_use(Field, AccessModules, ExceptedAccessTypes) ->
  current_legacy_use( Field
                    , AccessModules
                    , ExceptedAccessTypes
                    , all_modules(non_otp_directories(code:get_path()))
                    , fun abstract_code_analysis:get_module_abstract/1
                    ).

-spec current_legacy_use( field_descriptor()
                        , [module()]
                        , [abstract_code_analysis:record_access_type()]
                        , [module()]
                        , get_abstract_fun()
                        ) ->
                            usage_count_list().

current_legacy_use( Field
                  , AccessModules
                  , ExceptedAccessTypes
                  , Beams
                  , GetAbstractFun
                  ) ->
  {_Modules, RecordFieldUse, FileUse} = data_from_beams(GetAbstractFun, Beams),
  case dict:find(Field, RecordFieldUse) of
    error -> [];
    {ok, Usage} ->
      {[], Legacy} =
        separated_questionable_usage( Usage
                                    , [ {access_modules, AccessModules}
                                      , { excepted_access_types
                                        , ExceptedAccessTypes
                                        }
                                      ]
                                    , FileUse
                                    ),
     count_by_module(Legacy)
  end.

-spec count_by_module(usage_list()) -> usage_count_list().
count_by_module(Usage) ->
  dict:to_list(
    lists:foldl( fun({Module, _Line, _AccessType}, Dict) ->
                     dict:update_counter(Module, 1, Dict)
                 end
               , dict:new()
               , Usage
               )
   ).

restrictions_from_file() ->
  {ok, Restrictions} =
    file:consult(restriction_file_location()),
  Restrictions.

restriction_file_location() ->
  application:get_env(?APPLICATION, record_field_use_file, "record_field_use.eterm").

%%% Local Variables:
%%% erlang-indent-level: 2
%%% End:
