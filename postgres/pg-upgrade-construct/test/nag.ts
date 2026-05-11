import * as cdk from "aws-cdk-lib"
import * as PgUpgrade from "../lib/index"
import * as ec2 from "aws-cdk-lib/aws-ec2"
import * as rds from "aws-cdk-lib/aws-rds"
import { Aspects } from "aws-cdk-lib"
import { AwsSolutionsChecks, NagSuppressions } from "cdk-nag"

const app = new cdk.App()
const stack = new cdk.Stack(app, "NagStack")
const vpc = new ec2.Vpc(stack, "NagVpc")
const cluster = new rds.DatabaseCluster(stack, "NagCluster", {
    engine: rds.DatabaseClusterEngine.AURORA,
    instanceProps: { vpc },
})
const securityGroup = new ec2.SecurityGroup(stack, "NagSecurityGroup", {
    vpc
})
const secretsEndpoint = new ec2.InterfaceVpcEndpoint(stack, "NagEndpoint", {
    vpc, 
    service: ec2.InterfaceVpcEndpointAwsService.SECRETS_MANAGER,
    securityGroups: [securityGroup],
    subnets: {
        subnetFilters: [ec2.SubnetFilter.onePerAz()]
    }
})

const pgUpgrade = new PgUpgrade.PgUpgrade(stack, "NagConstruct", {
    schemaFolder: "test/schema",
    buildFolder: "test/build",
    verbose: true,
    vpc, 
    cluster,
    secretsEndpoint,
    securityGroups: [],
    region: "us-east-1",
    schemaName: "public"
})

// /NagStack/NagConstruct/pg-upgrade/Role/DefaultPolicy/Resource] AwsSolutions-IAM5[Action::s3:GetObject*]
NagSuppressions.addResourceSuppressionsByPath(stack,
    "/NagStack/NagConstruct/pg-upgrade/Role/DefaultPolicy/Resource",
    [{
        id: "AwsSolutions-IAM5",
        reason: "The CDK library controls these actions, which are necessary for bucket deployment to function and are limited to specific resources created by this stack.",
        appliesTo: [
            "Action::s3:GetObject*",
            "Action::s3:GetBucket*",
            "Action::s3:List*",
            "Resource::arn:<AWS::Partition>:ec2:<AWS::Region>:<AWS::AccountId>:network-interface/*",
            "Resource::arn:<AWS::Partition>:logs:<AWS::Region>:<AWS::AccountId>:log-group:/aws/codebuild/<NagConstructpgupgradeB75E8D16>:*",
            "Resource::arn:<AWS::Partition>:codebuild:<AWS::Region>:<AWS::AccountId>:report-group/<NagConstructpgupgradeB75E8D16>-*", 
            "Action::kms:ReEncrypt*", 
            "Action::kms:GenerateDataKey*"
        ]
    }],
    true)

// [Error at /NagStack/NagConstruct/pg-upgrade/PolicyDocument/Resource] AwsSolutions-IAM5[Resource::*]:

NagSuppressions.addResourceSuppressionsByPath(stack,
    "/NagStack/NagConstruct/pg-upgrade/PolicyDocument/Resource",
    [{
        id: "AwsSolutions-IAM5",
        reason: "The CDK library controls these actions, which are necessary for bucket deployment to function and are limited to specific resources created by this stack.",
        appliesTo: [
            "Resource::*"
        ]
    }],
    true)

// [Error at /NagStack/NagConstruct/invoker/ServiceRole/Resource] AwsSolutions-IAM4[Policy::arn:<AWS::Partition>:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole]: The IAM user, role, or group uses AWS managed policies.
 
NagSuppressions.addResourceSuppressionsByPath(stack,
    "/NagStack/NagConstruct/invoker/ServiceRole/Resource",
    [{
        id: "AwsSolutions-IAM4",
        reason: "This is controlled by the CDK lib, and the managed policy is correct",
        appliesTo: [
            "Policy::arn:<AWS::Partition>:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole", 
            "Policy::arn:<AWS::Partition>:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
        ]
    }],
    true)

// [Error at "/NagStack/NagConstruct/up-invoke-prov/framework-onTimeout/Resource"] AwsSolutions-L1: The non-container Lambda function is not configured to use the latest runtime version. .

NagSuppressions.addResourceSuppressionsByPath(stack,
    "/NagStack/NagConstruct/up-invoke-prov/framework-isComplete/Resource",
    [{
        id: "AwsSolutions-L1",
        reason: "This is controlled by the CDK lib",
    }],
    true)

NagSuppressions.addResourceSuppressionsByPath(stack,
    "/NagStack/NagConstruct/up-invoke-prov/framework-onTimeout/Resource",
    [{
        id: "AwsSolutions-L1",
        reason: "This is controlled by the CDK lib",
    }],
    true)

NagSuppressions.addResourceSuppressionsByPath(stack,
    "/NagStack/NagConstruct/up-invoke-prov/framework-onEvent/Resource",
    [{
        id: "AwsSolutions-L1",
        reason: "This is controlled by the CDK lib",
    }],
    true)

// [Error at /NagStack/NagConstruct/up-invoke-prov/framework-onTimeout/ServiceRole/DefaultPolicy/Resource] AwsSolutions-IAM5[Resource::<NagConstructinvoker955D8BEC.Arn>:*]: The IAM entity contains wildcard permissions and does not have a cdk-nag rule suppression with evidence for those permission.
NagSuppressions.addResourceSuppressionsByPath(stack,
    "/NagStack/NagConstruct/up-invoke-prov/framework-onTimeout/ServiceRole/DefaultPolicy/Resource",
    [{
        id: "AwsSolutions-IAM5",
        reason: "The CDK library controls these actions, which are necessary for the resource provider to function and are limited to specific resources created by this stack.",
        appliesTo: [
            "Resource::<NagConstructinvoker955D8BEC.Arn>:*",
            "Resource::<NagConstructiscompleteB345715A.Arn>:*"
        ]
    }],
    true)

// [Error at /NagStack/NagConstruct/is-complete/ServiceRole/Resource] AwsSolutions-IAM4[Policy::arn:<AWS::Partition>:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole]: The IAM user, role, or group uses AWS managed policies.
NagSuppressions.addResourceSuppressionsByPath(stack,
    "/NagStack/NagConstruct/is-complete/ServiceRole/Resource",
    [{
        id: "AwsSolutions-IAM4",
        reason: "This is controlled by the CDK lib, and the managed policy is correct",
        appliesTo: [
            "Policy::arn:<AWS::Partition>:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
            "Policy::arn:<AWS::Partition>:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
        ]
    }],
    true)

// [Error at /NagStack/NagConstruct/up-invoke-prov/framework-onEvent/ServiceRole/Resource] AwsSolutions-IAM4[Policy::arn:<AWS::Partition>:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole]: The IAM user, role, or group uses AWS managed policies.
NagSuppressions.addResourceSuppressionsByPath(stack,
    "/NagStack/NagConstruct/up-invoke-prov/framework-onEvent/ServiceRole/Resource",
    [{
        id: "AwsSolutions-IAM4",
        reason: "This is controlled by the CDK lib, and the managed policy is correct",
        appliesTo: [
            "Policy::arn:<AWS::Partition>:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
        ]
    }],
    true)

// [Error at /NagStack/NagConstruct/up-invoke-prov/waiter-state-machine/Role/DefaultPolicy/Resource] AwsSolutions-IAM5[Resource::<NagConstructupinvokeprovframeworkisCompleteCFE3A35A.Arn>:*]: The IAM entity contains wildcard permissions and does not have a cdk-nag rule suppression with evidence for those permission.
NagSuppressions.addResourceSuppressionsByPath(stack,
    "/NagStack/NagConstruct/up-invoke-prov/waiter-state-machine/Role/DefaultPolicy/Resource",
    [{
        id: "AwsSolutions-IAM5",
        reason: "The CDK library controls these actions, which are necessary for the resource provider to function and are limited to specific resources created by this stack.",
        appliesTo: [
            "Resource::<NagConstructupinvokeprovframeworkisCompleteCFE3A35A.Arn>:*", 
            "Resource::<NagConstructupinvokeprovframeworkonTimeoutC18861A0.Arn>:*"
        ]
    }],
    true)

// [Error at /NagStack/NagConstruct/is-complete/ServiceRole/Resource] AwsSolutions-IAM4[Policy::arn:<AWS::Partition>:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole]: The IAM user, role, or group uses AWS managed policies.
NagSuppressions.addResourceSuppressionsByPath(stack,
    "/NagStack/NagConstruct/is-complete/ServiceRole/Resource",
    [{
        id: "AwsSolutions-IAM4",
        reason: "This is controlled by the CDK lib, and the managed policy is correct",
        appliesTo: [
            "Policy::arn:<AWS::Partition>:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
        ]
    }],
    true)

// [Error at /NagStack/NagConstruct/up-invoke-prov/framework-onEvent/ServiceRole/DefaultPolicy/Resource] AwsSolutions-IAM5[Resource::<NagConstructinvoker955D8BEC.Arn>:*]: The IAM entity contains wildcard permissions and does not have a cdk-nag rule suppression with evidence for those permission.
NagSuppressions.addResourceSuppressionsByPath(stack,
    "/NagStack/NagConstruct/up-invoke-prov/framework-onEvent/ServiceRole/DefaultPolicy/Resource",
    [{
        id: "AwsSolutions-IAM5",
        reason: "The CDK library controls these actions, which are necessary for the resource provider to function and are limited to specific resources created by this stack.",
        appliesTo: [
            "Resource::<NagConstructinvoker955D8BEC.Arn>:*",
            "Resource::<NagConstructiscompleteB345715A.Arn>:*"
        ]
    }],
    true)
 
// [Error at /NagStack/NagConstruct/up-invoke-prov/framework-isComplete/ServiceRole/Resource] AwsSolutions-IAM4[Policy::arn:<AWS::Partition>:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole]: The IAM user, role, or group uses AWS managed policies.
NagSuppressions.addResourceSuppressionsByPath(stack,
    "/NagStack/NagConstruct/up-invoke-prov/framework-isComplete/ServiceRole/Resource",
    [{
        id: "AwsSolutions-IAM4",
        reason: "This is controlled by the CDK lib, and the managed policy is correct",
        appliesTo: [
            "Policy::arn:<AWS::Partition>:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
        ]
    }],
    true)

NagSuppressions.addResourceSuppressionsByPath(stack,
    "/NagStack/NagConstruct/up-invoke-prov/framework-isComplete/ServiceRole/DefaultPolicy/Resource",
    [{
        id: "AwsSolutions-IAM5",
        reason: "The CDK library controls these actions, which are necessary for the resource provider to function and are limited to specific resources created by this stack.",
        appliesTo: [
            "Resource::<NagConstructinvoker955D8BEC.Arn>:*",
            "Resource::<NagConstructiscompleteB345715A.Arn>:*"
        ]
    }],
    true)

// [Error at /NagStack/NagConstruct/up-invoke-prov/framework-onTimeout/ServiceRole/Resource] AwsSolutions-IAM4[Policy::arn:<AWS::Partition>:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole]: The IAM user, role, or group uses AWS managed policies.
NagSuppressions.addResourceSuppressionsByPath(stack,
    "/NagStack/NagConstruct/up-invoke-prov/framework-onTimeout/ServiceRole/Resource",
    [{
        id: "AwsSolutions-IAM4",
        reason: "This is controlled by the CDK lib, and the managed policy is correct",
        appliesTo: [
            "Policy::arn:<AWS::Partition>:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
        ]
    }],
    true)


Aspects.of(pgUpgrade).add(new AwsSolutionsChecks())

