const aws = require("aws-sdk")

/**
 * Lambda function handler to invoke the CodeBuild job that uses the 
 * pg-upgrade CLI to upgrade your database schema.
 *
 * We don't actualy run the upgrade from here, since schema changes can sometimes 
 * take a long time, and we don't want to hit any timeouts.
 */
async function handler(event) {
    console.log({event})

    let isComplete = true

    if (event.RequestType === "Delete") {
        console.log("No action to take on delete")
        return { "IsComplete": isComplete }
    }

    const projectName = process.env.PROJECT_NAME
    console.log({projectName})

    const cb = new aws.CodeBuild()
    const response = await cb.startBuild({projectName}).promise()
    console.log({response})
    
    return { "IsComplete": isComplete }
}

module.exports = { handler }


