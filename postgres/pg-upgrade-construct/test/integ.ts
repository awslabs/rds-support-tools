import * as cdk from "aws-cdk-lib"
import * as PgUpgrade from "../lib/index"
import * as ec2 from "aws-cdk-lib/aws-ec2"
import * as rds from "aws-cdk-lib/aws-rds"
import * as path from "path"

const app = new cdk.App()
const stack = new cdk.Stack(app, "IntegStack")
const vpc = new ec2.Vpc(stack, "IntegVpc")
const cluster = new rds.DatabaseCluster(stack, "IntegCluster", {
    engine: rds.DatabaseClusterEngine.AURORA,
    instanceProps: { vpc },
})
const securityGroup = new ec2.SecurityGroup(stack, "IntegSecurityGroup", {
    vpc
})
const secretsEndpoint = new ec2.InterfaceVpcEndpoint(stack, "IntegEndpoint", {
    vpc, 
    service: ec2.InterfaceVpcEndpointAwsService.SECRETS_MANAGER,
    securityGroups: [securityGroup],
    subnets: {
        subnetFilters: [ec2.SubnetFilter.onePerAz()]
    }
})

new PgUpgrade.PgUpgrade(stack, "IntegConstruct", {
    schemaFolder: path.join(__dirname, "schema"),
    buildFolder: path.join(__dirname, "build") ,
    verbose: true,
    vpc, 
    cluster,
    secretsEndpoint,
    securityGroups: [],
    region: "us-east-1",
    schemaName: "public"
})


