#!/usr/bin/env escript
%% -*- erlang -*-
%%! +A0
main([]) ->
  AppStrings = string:tokens(os:getenv("OUR_APPS"), " "),
  Directories = [code:lib_dir(list_to_atom(AppString), ebin) || AppString <- AppStrings],
  Issues = record_use_check:gather_violations(Directories),
  ReportableIssues =
    case os:getenv("BUILD") of
      "test" -> Issues;
      _ -> lists:filter(fun record_use_check:is_reportable_in_non_test_builds/1, Issues)
    end,
  lists:foreach(fun record_use_check:handle_violation/1, ReportableIssues),
  case lists:any(fun record_use_check:is_real_violation/1, ReportableIssues) of
    false -> ok;
    true  -> halt(1)
  end.
