import * as cdk from "aws-cdk-lib"
import { Template } from "aws-cdk-lib/assertions"
import * as PgUpgrade from "../lib/index"
import * as ec2 from "aws-cdk-lib/aws-ec2"
import * as rds from "aws-cdk-lib/aws-rds"

test("Resources Created", () => {
    const app = new cdk.App()
    const stack = new cdk.Stack(app, "TestStack")
    const vpc = new ec2.Vpc(stack, "TestVpc")
    const cluster = new rds.DatabaseCluster(stack, "TestCluster", {
        engine: rds.DatabaseClusterEngine.AURORA,
        instanceProps: { vpc },
    })
    const securityGroup = new ec2.SecurityGroup(stack, "TestSecurityGroup", {
        vpc
    })
    const secretsEndpoint = new ec2.InterfaceVpcEndpoint(stack, "TestEndpoint", {
        vpc, 
        service: ec2.InterfaceVpcEndpointAwsService.SECRETS_MANAGER,
        securityGroups: [securityGroup],
        subnets: {
            subnetFilters: [ec2.SubnetFilter.onePerAz()]
        }
    })

    // WHEN
    new PgUpgrade.PgUpgrade(stack, "MyTestConstruct", {
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
    // THEN
    const template = Template.fromStack(stack)

    template.hasResourceProperties("AWS::S3::Bucket", {
        "BucketEncryption": {
            "ServerSideEncryptionConfiguration": [
                {
                    "ServerSideEncryptionByDefault": {
                        "SSEAlgorithm": "AES256"
                    }
                }
            ]
        }
    })
})

/*
 *
 * This is an alternate way to do the nag tests, instead of a separate file.
 
import { Aspects } from "aws-cdk-lib"
import { AwsSolutionsChecks } from "cdk-nag"

describe('cdk-nag AwsSolutions Pack', () => {
  let stack: Stack;
  let app: App;
  beforeAll(() => {
    // GIVEN
    app = new App();
    stack = new MyStack(app, 'test');

    // WHEN
    Aspects.of(stack).add(new AwsSolutionsChecks());
  });

  // THEN
  test('No unsuppressed Warnings', () => {
    const warnings = Annotations.fromStack(stack).findWarning(
      '*',
      Match.stringLikeRegexp('AwsSolutions-.*')
    );
    expect(warnings).toHaveLength(0);
  });

  test('No unsuppressed Errors', () => {
    const errors = Annotations.fromStack(stack).findError(
      '*',
      Match.stringLikeRegexp('AwsSolutions-.*')
    );
    expect(errors).toHaveLength(0);
  });
});

*/
