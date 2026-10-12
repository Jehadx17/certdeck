# AWS Certified Developer - Associate (DVA-C02) exam guide: task statements
Source: https://docs.aws.amazon.com/aws-certification/latest/developer-associate-02/
Weights: 1 Development with AWS Services 32%, 2 Security 26%, 3 Deployment 24%, 4 Troubleshooting and Optimization 18%. 65 questions (50 scored), 130 minutes, scaled 100-1000, pass 720. Question types: multiple choice and multiple response.

## Domain 1: Development with AWS Services

### Task 1: Develop code for applications hosted on AWS
Skills: Describe architectural patterns (e.g. event-driven, microservices, monolithic, choreography, orchestration, fanout); Describe differences between stateful and stateless concepts; Describe differences between tightly coupled and loosely coupled components; Describe differences between synchronous and asynchronous patterns; Create fault-tolerant and resilient applications in a programming language (e.g. Java, C#, Python, JavaScript, TypeScript, Go); Create, extend, and maintain APIs (e.g. response/request transformations, enforcing validation rules, overriding status codes); Write and run unit tests in development environments (e.g. using AWS SAM); Write code to use messaging services; Write code that interacts with AWS services by using APIs and AWS SDKs; Handle streaming data using AWS services; Use Amazon Q Developer to assist with development; Use Amazon EventBridge to implement event-driven patterns; Implement resilient application code for third-party service integrations (e.g. retry logic, circuit breakers, error handling patterns).

### Task 2: Develop code for AWS Lambda
Skills: Describe the access of private resources in VPCs from Lambda code; Configure Lambda functions by defining environment variables and parameters (e.g. memory, concurrency, timeout, runtime, handler, layers, extensions, triggers, destinations); Handle the event lifecycle and errors by using code (e.g. Lambda Destinations, dead-letter queues); Write and run test code by using AWS services and tools; Integrate Lambda functions with AWS services; Tune Lambda functions for optimal performance; Use Lambda functions to process and transform data in near real time.

### Task 3: Use data stores in application development
Skills: Describe high-cardinality partition keys for balanced partition access; Describe database consistency models (e.g. strongly consistent, eventually consistent); Describe differences between query and scan operations; Define Amazon DynamoDB keys and indexing; Serialize and deserialize data to provide persistence to a data store; Use, manage, and maintain data stores; Manage data lifecycles; Use data caching services; Use specialized data stores based on access patterns (e.g. Amazon OpenSearch Service).

## Domain 2: Security

### Task 1: Implement authentication and/or authorization for applications and AWS services
Skills: Use an identity provider to implement federated access (e.g. Amazon Cognito, IAM); Secure applications by using bearer tokens; Configure programmatic access to AWS; Make authenticated calls to AWS services; Assume an IAM role; Define permissions for IAM principals; Implement application-level authorization for fine-grained access control; Handle cross-service authentication in microservice architectures.

### Task 2: Implement encryption by using AWS services
Skills: Define encryption at rest and in transit; Describe certificate management (e.g. AWS Private CA); Describe differences between client-side encryption and server-side encryption; Use encryption keys to encrypt or decrypt data; Generate certificates and SSH keys for development purposes; Use encryption across account boundaries; Enable and disable key rotation.

### Task 3: Manage sensitive data in application code
Skills: Describe data classification (e.g. personally identifiable information [PII], protected health information [PHI]); Encrypt environment variables that contain sensitive data; Use secret management services to secure sensitive data; Sanitize sensitive data; Implement application-level data masking and sanitization; Implement data access patterns for multi-tenant applications.

## Domain 3: Deployment

### Task 1: Prepare application artifacts to be deployed to AWS
Skills: Manage the dependencies of the code module (e.g. environment variables, configuration files, container images) within the package; Organize files and a directory structure for application deployment; Use code repositories in deployment environments; Apply application requirements for resources (e.g. memory, cores); Prepare application configurations for specific environments (e.g. by using AWS AppConfig).

### Task 2: Test applications in development environments
Skills: Test deployed code by using AWS services and tools; Write integration tests and mock APIs for external dependencies; Test applications by using development endpoints (e.g. configuring stages in Amazon API Gateway); Deploy application stack updates to existing environments (e.g. deploying an AWS SAM template to a different staging environment); Test event-driven applications.

### Task 3: Automate deployment testing
Skills: Create application test events (e.g. JSON payloads for testing AWS Lambda, API Gateway, AWS SAM resources); Deploy API resources to various environments; Create application environments that use approved versions for integration testing (e.g. Lambda aliases, container image tags, AWS Amplify branches, AWS Copilot environments); Implement and deploy infrastructure as code (IaC) templates (e.g. AWS SAM templates, AWS CloudFormation templates); Manage environments in individual AWS services (e.g. differentiating between development, test, and production in API Gateway); Use Amazon Q Developer to generate automated tests.

### Task 4: Deploy code by using AWS Continuous Integration and Continuous Delivery (CI/CD) services
Skills: Describe Lambda deployment packaging options; Describe API Gateway stages and custom domains; Update existing IaC templates (e.g. AWS SAM templates, CloudFormation templates); Manage application environments by using AWS services; Deploy an application version by using deployment strategies; Commit code to a repository to invoke build, test, and deployment actions; Use orchestrated workflows to deploy code to different environments; Perform application rollbacks by using existing deployment strategies; Use labels and branches for version and release management; Use existing runtime configurations to create dynamic deployments (e.g. using staging variables from API Gateway in Lambda functions); Configure deployment strategies (e.g. blue/green, canary, rolling) for application releases.

## Domain 4: Troubleshooting and Optimization

### Task 1: Assist in a root cause analysis
Skills: Debug code to identify defects; Interpret application metrics, logs, and traces; Query logs to find relevant data; Implement custom metrics (e.g. Amazon CloudWatch embedded metric format [EMF]); Review application health by using dashboards and insights; Troubleshoot deployment failures by using service output logs; Debug service integration issues in applications.

### Task 2: Instrument code for observability
Skills: Describe differences between logging, monitoring, and observability; Implement an effective logging strategy to record application behavior and state; Implement code that emits custom metrics; Add annotations for tracing services; Implement notification alerts for specific actions (e.g. notifications about quota limits or deployment completions); Implement tracing by using AWS services and tools; Implement structured logging for application events and user actions; Configure application health checks and readiness probes.

### Task 3: Optimize applications by using AWS services and features
Skills: Define concurrency; Profile application performance; Determine minimum memory and compute power for an application; Use subscription filter policies to optimize messaging; Cache content based on request headers; Implement application-level caching to improve performance; Optimize application resource usage; Analyze application performance issues; Use application logs to identify performance bottlenecks.
