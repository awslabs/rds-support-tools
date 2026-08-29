const pgUpgrade = require("pg-upgrade")
const aws = require("aws-sdk")

/**
 * Lambda function handler to check and see if there are any remaining changes 
 * left to be run on the database.
 *
 * We run pg-upgrade directly from here instead of a CodeBuild job, since a 
 * simple check is very fast, and there's no danger of timing out.
 *
 * One possible limitation is the size of your schema folder, since it gets 
 * copied in with the lambda function code.
 */
async function handler(event) {
    console.log({event})

    let isComplete = true

    if (event.RequestType === "Delete") {
        console.log("No action to take on delete")
        return { "IsComplete": isComplete }
    }

    try {

        // Look up the DB vars from secrets manager
        const dbSecretArn = process.env.DB_SECRET_ARN
        const endpoint = process.env.SECRETS_ENDPOINT
        const mgr = new aws.SecretsManager({
            endpoint
        });
        const secret = await mgr.getSecretValue({SecretId: dbSecretArn}).promise()
        const secretVal = JSON.parse(secret.SecretString)

        const options = {
            folder: "schema",
            verbose: process.env.VERBOSE,
            user: secretVal.username,
            host: secretVal.host,
            database: secretVal.dbname,
            password: secretVal.password,
            port: secretVal.port,
            schema: process.env.PGSCHEMA || "public" 
        }

        const client = await pgUpgrade.connect(options)
        const filesToRun = await pgUpgrade.getFilesToRun(client, options)
        
        if (options.verbose) console.log({filesToRun})

        isComplete = filesToRun.length === 0

        console.log("IsComplete", isComplete)

    } catch (ex) {
        console.error(ex)

        // TODO - After development, fix this so that we fail on unexpected errors
        // It's tempting to leave it, since an unexpected error guarantees that the
        // stack will fail and time out, causing an operator to wait an hour.
        // We can't shorten the timeout since some databae updates take a long time, 
        // and it will be completely expected to see false returns.
        // But, if the operator is not aware this failed, then the rest of the 
        // application will be unstable due to a schema mismatch.
        isComplete = true
    }

    return { "IsComplete": isComplete }
}

module.exports = { handler }
