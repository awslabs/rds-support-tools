#!/usr/bin/env node
const cli = require("commander")
const { Client } = require("pg")
const pgPass = require("pgpass")
const fs = require("fs-extra")
const path = require("path")
const { getNowString } = require("./helpers")

/**
 * Connect to the database and return a client.
 */
async function connect(options) {
    if (!options.host) options.host = process.env.PGHOST
    if (!options.user) options.user = process.env.PGUSER
    if (!options.database) options.database = process.env.PGDATABASE
    if (!options.port) options.port = process.env.PGPORT || "5432"
    if (!options.schema) options.schema = process.env.PGSCHEMA
    if (!options.password) options.password = process.env.PGPASSWORD

    if (!options.password) {
        // Read from ~/.pgpass
        options.password = await getPgpass(options)
    }

    const client = new Client({
      user: options.user,
      host: options.host,
      database: options.database,
      password: options.password,
      port: options.port,
    })
    client.connect()

    try {
        // Change the default schema so we don't have to prefix everything.
        // In a user-facing app this would be an injection vulnerability, but this 
        // script is run by admins with controlled input so it should be fine.
        await client.query(`set search_path to ${options.schema}`)
    } catch (ex) {
        console.error(ex) 
        await client.end()
        return undefined
    }

    return client
}

/**
 * Read the password from .pgpass
 */
async function getPgpass(options) {
    const connInfo = {
      'host' : options.host,
      'user' : options.user,
    }

    if (options.verbose) console.log({connInfo})

    return new Promise((resolve, reject) => {
        pgPass(connInfo, function(pass){
            if (pass === undefined) reject("Failed to read password")
            else resolve(pass)
        })
    })
}

/**
 * Check to see if our `schema_change` table exists.
 */
async function checkForUpgradeTable(client, options, showError) {
    const sql = `
select * from information_schema.tables
where table_name = 'schema_change'
and table_schema = $1
`
    const result = await client.query(sql, [options.schema])

    const exists = result.rows && result.rows.length > 0

    if (!exists && showError) {
        console.error("The schema_change table does not exist, see the init command")
    }

    return exists
}

/**
 * Run the changes.
 */
async function run(options) {
    if (options.verbose) console.log("run", {options})

    const client = await connect(options)

    const schemaTableExists = await checkForUpgradeTable(client, options, true)

    if (!schemaTableExists) {
        await client.end()
        return false
    }

    // Schema changes
    const files = await getFilesToRun(client, options)
    if (files.length === 0) console.log(`No new files found in ${options.folder}/`)
    const ran = []
    let succeeded = true
    for (const fileName of files) {
        const contents = fs.readFileSync(path.join(options.folder, fileName), { encoding: "utf-8" })
        if (options.verbose) console.log(contents)
        try {
            // Run the change script
            await runContentsOfFile(client, options, contents)
            console.log("Ran OK:", fileName)
            ran.push(fileName)

            // Store the fact that we ran it
            await client.query("insert into schema_change (file_name) values ($1)", [fileName])

        } catch (ex) {
            console.error("FAILED:", fileName)
            console.error(ex)
            succeeded = false
            ran.push(fileName)
            break
        }
    }

    if (!succeeded) {
        console.log("Stopping...")
        for (const fileName of files) {
            if (!ran.includes(fileName)) {
                console.log("Not attempted:", fileName)
            }
        }
    }

    // Procedures
    const procFiles = await getProceduresToRun(options)
    let numOk = 0
    let numFailed = 0
    for (const fileName of procFiles) {
        const contents = fs.readFileSync(path.join(options.folder, "procedures", fileName), { encoding: "utf-8" })
        if (options.verbose) console.log(contents)
        try {
            // Run the procedure 
            await runContentsOfFile(client, options, contents)
            numOk++
        } catch (ex) {
            console.error("FAILED:", fileName)
            console.error(ex)
            numFailed++
        }
    }
    console.log(`Done running procedures. ${numOk} succeeded, ${numFailed} failed`)

    await client.end()
}

/**
 * Run the contents of a file.
 * 
 * There might be some weird delimiter issues we have to deal with at some point, 
 * but with standard formatting, simply passing the contents of the file works fine.
 */
async function runContentsOfFile(client, options, content) {
    await client.query(content)
}

/**
 * Get the list of files that have already been run.
 */
async function alreadyRan(client, options) {

    let rows
    try {
        const result = await client.query("select file_name from schema_change order by file_name")
        rows = result.rows
    } catch (ex) {
        console.error(ex)
        throw ex
    }

    const already = []
    for (const row of rows) already.push(row["file_name"])

    return already
}

/**
 * Get a list of procedures to run. 
 *
 * This returns all `*.sql` files in the `folder/procedures` directory.
 */
async function getProceduresToRun(options) {

    const procFolder = path.join(options.folder, "procedures")
    if (!fs.existsSync(procFolder)) return []

    const re = new RegExp("^.*\\.sql")
    
    return fs.readdirSync(procFolder, {withFileTypes: true})
        .filter(item => !item.isDirectory())
        .filter(item => re.test(item.name)) 
        .map(item => item.name)
        .sort()
}

/**
 * Get a list of files that have not yet been run on the database.
 *
 * Does not include procedures.
 */
async function getFilesToRun(client, options) {

    let already
    try {
        already = await alreadyRan(client, options)
    } catch (ex) {
        await client.end()
        return false
    }

    if (options.verbose) console.log({already})

    const re = new RegExp("^\\d\\d\\d\\d-\\d\\d-\\d\\d.*\\.sql")
    
    return fs.readdirSync(options.folder, {withFileTypes: true})
        .filter(item => !item.isDirectory())
        .filter(item => re.test(item.name)) 
        .filter(item => !already.includes(item.name))
        .map(item => item.name)
        .sort()
}

/**
 * Show new files that will be run.
 */
async function show(options) {
    if (options.verbose) console.log("show", {options})

    const client = await connect(options)

    const schemaTableExists = await checkForUpgradeTable(client, options, true)

    if (!schemaTableExists) {
        await client.end()
        return false
    }

    const files = await getFilesToRun(client, options)
    files.forEach(name => console.log(name))

    await client.end()
}

const TEST_DB_PREFIX = "test_upgrade_"

/**
 * Create a new database to use for testing your schema upgrades.
 */
async function createTestDatabase(client, options) {
    const name = `${TEST_DB_PREFIX}${getNowString()}`
    try {
        const sql = `create database ${name}`
        if (options.verbose) console.log(sql)
        await client.query(sql)
    } catch (ex) {
        console.error(ex)
        throw ex
    }
    return name
}

/**
 * Create a new database, run all changes and procedures, then delete the database.
 */
async function test(options) {
    if (options.verbose) console.log("test", {options})

    // Create the new database using the existing client
    const client = await connect(options)
    const name = await createTestDatabase(client, options)
    await client.end()

    if (options.verbose) console.log("Created test database", name)

    // Make a new copy of the options, replacing the database name
    const testOptions = Object.assign({}, options)
    testOptions.database = name
    testOptions.schema = "public"

    // Initialize the test database
    await init(testOptions)

    // Run all changes from the beginning
    await run(testOptions)

    console.log("Test completed successfully")

    // If we don't want to keep the new database around for troubleshooting, drop it
    if (!options.keep) {
        await dropTestDatabase(options, name)
        console.log("Test database dropped")
    }

}

/**
 * Drop the test database.
 *
 * Options should configure a different database than the one to drop.
 */
async function dropTestDatabase(options, databaseToDrop) {
    if (!databaseToDrop.startsWith(TEST_DB_PREFIX)) {
        throw Error("This does not look like a test database:" + options.database)
    }
    const client = await connect(options)
    await client.query(`drop database ${databaseToDrop}`)
    await client.end()
}

/**
 * Create the schema_change table in your database to track changes
 */
async function init(options) {
    if (options.verbose) console.log("init", {options})

    const client = await connect(options)

    const schemaTableExists = await checkForUpgradeTable(client, options, false)
    if (schemaTableExists) {
        console.log("The schema_change table already exists")
        await client.end()
        return
    }

    try {
        await client.query(`create table schema_change(file_name varchar(255) not null primary key)`)
    } catch (ex) {
        console.error(ex)
    }

    await client.end()

    console.log("Created schema_change table")
}

function main() {
    
    cli.name("pg-upgrade")
    cli.description("Postgresql Schema Upgrade")
    cli.version("0.1.5")

    cli.option("-v, --verbose", "Output verbose statements to the console")

    cli.requiredOption("-f, --folder [folder]", "The folder where change scripts are stored")

    cli.option("-h, --host [host]", "Database host (or PGHOST environment variable)")

    cli.option("-d, --database [database]", "Database name (or PGDATABASE environment variable)")

    cli.option("-s, --schema [schema]", "Database schema (or PGSCHEMA environment variable)")

    cli.option("-p, --port [port]", "Database port (or PGPORT environment variable)")

    cli.option("-u, --user [user] ", "Database user (or PGUSER environment variable). Password must be in .pgpass")

    cli.command("run")
        .description("Run the changes")
        .action(function() { run(this.optsWithGlobals()) })

    cli.command("show")
        .description("Show the changes that will be made with the run command")
        .action(function() { show(this.optsWithGlobals()) })

    cli.command("test")
        .description("Create a test database and run all schema changes")
        .option("-k, --keep", "Do not delete the test database when finished")
        .action(function() { test(this.optsWithGlobals()) })

    cli.command("init")
        .description("Create the schema_change table in your database to track changes")
        .action(function() { init(this.optsWithGlobals()) })

    cli.parse()

}

// Run main if this was invoked from a terminal: $ node upgrade.js
if (require.main === module) {
    main()
}

module.exports = { connect, run, show, test, init, getFilesToRun }
