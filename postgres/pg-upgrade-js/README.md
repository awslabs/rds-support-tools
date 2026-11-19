# pg-upgrade

## Postgresql Schema Upgrade

_NOTE: This is an experimental package and not supported in any way!_

This utility runs a series of schema upgrade scripts in order, and then runs all stored routines, ensuring that the target database is up to date with all schema changes. It includes a useful testing option that creates a new empty database and runs all scripts on it, which can be used as part of CI/CD pipelines to make sure newly submitted changes are compatible with the existing schema.

### Usage

Export environment variables PGHOST, PGUSER, PGPORT, PGDATABASE, PGSCHEMA. Store your password in `~/.pgpass` 
(See (https://www.postgresql.org/docs/current/libpq-pgpass.html)[https://www.postgresql.org/docs/current/libpq-pgpass.html]).

```sh
npm install pg-upgrade
npx pg-upgrade init -f path/to/schema
npx pg-upgrade show -f path/to/schema
```

Files in the directory should be in the format `YYYY-MM-DD-HH-mm-Description.sql`, e.g. '2022-06-10-13-00-AddNewColumn.sql`.

(The minimal requirement is `0000-00-00.sql`, which means you could use invalid dates and simply increment the numbers, but it's nice to have a date on every change with a short description so you can remember when you made the change and why you made it.)

Inside that folder you may have another folder called `procedures`. Scripts in that folder do not have a naming convention, and they will *all* be run each time this script is invoked.

Sample structure:

```
    ./schema    
        2022-06-10-01-01-Initial.sql
        2022-06-10-02-00-AddSomething.sql
        procedures/
            user_get.sql
            user_save.sql
            user_delete.sql
            users_list.sql
```

### Options

```
Usage: pg-upgrade [options] [command]

Postgresql Schema Upgrade

Options:
  -V, --version              output the version number
  -v, --verbose              Output verbose statements to the console
  -f, --folder [folder]      The folder where change scripts are stored
  -h, --host [host]          Database host (or PGHOST environment variable)
  -d, --database [database]  Database name (or PGDATABASE environment variable)
  -s, --schema [schema]      Database schema (or PGSCHEMA environment variable)
  -p, --port [port]          Database port (or PGPORT environment variable)
  -u, --user [user]          Database user (or PGUSER environment variable). Password must be in .pgpass
  --help                     display help for command

Commands:
  run                        Run the changes
  show                       Show the changes that will be made with the run command
  test [options]             Create a test database and run all schema changes
  init                       Create the schema_change table in your database to track changes
  help [command]             display help for command
```

