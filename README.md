# Kappa
> Keep a huge Erlang code base, developed by multiple teams, in a manageable state

[![Build Status][ci-image]][ci-url]
[![License][license-image]][license-url]
[![Developed at Klarna][klarna-image]][klarna-url]

## Features

* Code and database table ownership. Kappa can tell you which team
  owns this particular app / module / database table and how they can
  be contacted (e.g. to send an alarm).
* Application's API modules. Restrict inter-app calls to only a set of
  API-modules. Calls from one app to other app's _private_ modules are
  not allowed.
* Restricted record fields usage. Direct access to records defined in
  header files makes it hard to change the record's structure. Kappa
  allows only a defined set of modules to access specific record's
  fields directly.
* Code layers. Divide your apps into multiple layers (e.g. external
  interfaces and APIs / business logic layer / database level / system
  utilities / test-only / external dependencies, etc.) and apply
  restrictions on calls between applications that belong to different
  layers (allowed at all?  if allowed, in which direction?)

Most of the checks rely on the presence of `debug_info` compiler
option!

## Configuration

Kappa's configuration is loaded from 4 files:

* `architecture_file` - where all the layers and applications are
  listed with their owner IDs and API modules
* `ownership_file` - with all the teams and their contact details
* `db_ownership_file` - where all the database tables are listed with
  their owners
* `record_field_use_file` - where all the shared records are listed
  together with their access modules and allowed exceptions

There are 2 additional files where approved rule violations can be listed:

* `approved_api_violations_file` - where we can temporary allow calls
  from one application to another application's non-API module
* `approved_layer_violations_file` - where we can temporary allow
  calls between applications belonging to layers, which are normally
  not allowed to communicate.

Their location can be configured via `kappa`'s application env, but
some functions can accept their location as an argument.

## Register as an API

Each application needs to have a block in `architecture_file` with an
`application` and `owner` keys.  Each API module also needs to be
listed under its application. Example:

    [ {application, monitor}
    , {owner, operations}
    , {api, [ alarm, log ]}
    ].

Where __owner__ is the name of your team, __application__ is the name
of application your api module belongs to and __api__ is a list of all
API modules.

### Add API exceptions

You can specify ignore rules to reduce the number of modules in the
api section and to avoid manually adding them. They are added to
`kappa`'s application env under `always_api` key.

Several types of rules are supported:

* ignore app_name: `app_name`. This will make modules with the same
  name as their applications be treated as API modules.
* ignore by suffix: `{suffix, "api"}`. This will make all modules with
  names ending in `api` be treated as API modules.
* ignore by prefix: `{prefix, "api"}`. This will make all modules with
  names starting with `api` be treated as API modules.
* ignore by directory: `{dir, "api"}`. This will make all modules,
  which source files are stored in `src/api` subdirectory be treated as
  API modules.
* ignore by behaviour: `{behaviour, api}`. This will make all modules
  with `-behaviour(api)` be treated as API modules.

Full example:

    {env, [
            {always_api, [
                       app_name,
                       {behaviour, api},
                       {dir, "api"}
                     ]
            }
          ]
    }

## How to contribute

See our guide on [contributing](.github/CONTRIBUTING.md).

## Release History

See our [changelog](CHANGELOG.md).

## License

Copyright © 2021 Klarna Bank AB

For license details, see the [LICENSE](LICENSE) file in the root of this project.

<!-- Markdown link & img dfn's -->
[ci-image]: https://img.shields.io/badge/build-passing-brightgreen?style=flat-square
[ci-url]: https://github.com/klarna-incubator/kappa
[license-image]: https://img.shields.io/badge/license-Apache%202-blue?style=flat-square
[license-url]: http://www.apache.org/licenses/LICENSE-2.0
[klarna-image]: https://img.shields.io/badge/%20-Developed%20at%20Klarna-black?labelColor=ffb3c7&style=flat-square&logo=data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAOCAYAAAAmL5yKAAAAAXNSR0IArs4c6QAAAIRlWElmTU0AKgAAAAgABQESAAMAAAABAAEAAAEaAAUAAAABAAAASgEbAAUAAAABAAAAUgEoAAMAAAABAAIAAIdpAAQAAAABAAAAWgAAAAAAAALQAAAAAQAAAtAAAAABAAOgAQADAAAAAQABAACgAgAEAAAAAQAAABCgAwAEAAAAAQAAAA4AAAAA0LMKiwAAAAlwSFlzAABuugAAbroB1t6xFwAAAVlpVFh0WE1MOmNvbS5hZG9iZS54bXAAAAAAADx4OnhtcG1ldGEgeG1sbnM6eD0iYWRvYmU6bnM6bWV0YS8iIHg6eG1wdGs9IlhNUCBDb3JlIDUuNC4wIj4KICAgPHJkZjpSREYgeG1sbnM6cmRmPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5LzAyLzIyLXJkZi1zeW50YXgtbnMjIj4KICAgICAgPHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9IiIKICAgICAgICAgICAgeG1sbnM6dGlmZj0iaHR0cDovL25zLmFkb2JlLmNvbS90aWZmLzEuMC8iPgogICAgICAgICA8dGlmZjpPcmllbnRhdGlvbj4xPC90aWZmOk9yaWVudGF0aW9uPgogICAgICA8L3JkZjpEZXNjcmlwdGlvbj4KICAgPC9yZGY6UkRGPgo8L3g6eG1wbWV0YT4KTMInWQAAAVBJREFUKBVtkz0vREEUhsdXgo5qJXohkUgQ0fgFNFpR2V5ClP6CQu9PiB6lEL1I7B9A4/treZ47c252s97k2ffMmZkz5869m1JKL/AFbzAHaiRbmsIf4BdaMAZqMFsOXNxXkroKbxCPV5l8yHOJLVipn9/vEreLa7FguSN3S2ynA/ATeQuI8tTY6OOY34DQaQnq9mPCDtxoBwuRxPfAvPMWnARlB12KAi6eLTPruOOP4gcl33O6+Sjgc83DJkRH+h2MgorLzaPy68W48BG2S+xYnmAa1L+nOxEduMH3fgjGFvZeVkANZau68B6CrgJxWosFFpF7iG+h5wKZqwt42qIJtARu/ix+gqsosEq8D35o6R3c7OL4lAnTDljEe9B3Qa2BYzmHemDCt6Diwo6JY7E+A82OnN9HuoBruAQvUQ1nSxP4GVzBDRyBfygf6RW2/gD3NmEv+K/DZgAAAABJRU5ErkJggg==
[klarna-url]: https://klarna.github.io
