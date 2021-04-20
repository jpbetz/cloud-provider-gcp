# KEP-647: APIServer Tracing

<!-- toc -->
- [Release Signoff Checklist](#release-signoff-checklist)
- [Summary](#summary)
- [Motivation](#motivation)
  - [Definitions](#definitions)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Proposal](#proposal)
  - [User Stories](#user-stories)
    - [Steady-State trace collection](#steady-state-trace-collection)
    - [On-Demand trace collection](#on-demand-trace-collection)
  - [Tracing API Requests](#tracing-api-requests)
  - [Exporting Spans](#exporting-spans)
  - [Running the OpenTelemetry Collector](#running-the-opentelemetry-collector)
  - [APIServer Configuration and EgressSelectors](#apiserver-configuration-and-egressselectors)
  - [Controlling use of the OpenTelemetry library](#controlling-use-of-the-opentelemetry-library)
  - [Test Plan](#test-plan)
- [Graduation requirements](#graduation-requirements)
- [Production Readiness Review Questionnaire](#production-readiness-review-questionnaire)
  - [Feature Enablement and Rollback](#feature-enablement-and-rollback)
  - [Rollout, Upgrade and Rollback Planning](#rollout-upgrade-and-rollback-planning)
  - [Monitoring Requirements](#monitoring-requirements)
  - [Dependencies](#dependencies)
  - [Scalability](#scalability)
  - [Troubleshooting](#troubleshooting)
- [Implementation History](#implementation-history)
- [Alternatives considered](#alternatives-considered)
  - [Introducing a new EgressSelector type](#introducing-a-new-egressselector-type)
  - [Other OpenTelemetry Exporters](#other-opentelemetry-exporters)
<!-- /toc -->

## Release Signoff Checklist

Items marked with (R) are required *prior to targeting to a milestone / release*.

- [X] (R) Enhancement issue in release milestone, which links to KEP dir in [kubernetes/enhancements] (not the initial KEP PR)
- [X] (R) KEP approvers have approved the KEP status as `implementable`
- [X] (R) Design details are appropriately documented
- [X] (R) Test plan is in place, giving consideration to SIG Architecture and SIG Testing input
- [X] (R) Graduation criteria is in place
- [x] (R) Production readiness review completed
- [ ] Production readiness review approved
- [X] "Implementation History" section is up-to-date for milestone
- [ ] User-facing documentation has been created in [kubernetes/website], for publication to [kubernetes.io]
- [ ] Supporting documentation—e.g., additional design documents, links to mailing list discussions/SIG meetings, relevant PRs/issues, release notes

## Summary

This Kubernetes Enhancement Proposal (KEP) proposes enhancing the API Server to allow tracing requests.  For this, it proposes using OpenTelemetry libraries, and exports in the OpenTelemetry format.

## Motivation

Along with metrics and logs, traces are a useful form of telemetry to aid with debugging incoming requests.  The API Server currently uses a poor-man's form of tracing (see [github.com/kubernetes/utils/trace](https://github.com/kubernetes/utils/tree/master/trace)), but we can make use of distributed tracing to improve the ease of use and enable easier analysis of trace data.  Trace data is structured, providing the detail necessary to debug requests, and context propagation allows plugins, such as admission webhooks, to add to API Server requests.

### Definitions

**Span**: The smallest unit of a trace.  It has a start and end time, and is attached to a single trace.
**Trace**: A collection of Spans which represents a single process.
**Trace Context**: A reference to a Trace that is designed to be propagated across component boundaries.  Sometimes referred to as the "Span Context".  It is can be thought of as a pointer to a parent span that child spans can be attached to.

### Goals

* The API Server generates and exports spans for incoming and outgoing requests.
* The API Server propagates context from incoming requests to outgoing requests.

### Non-Goals

* Tracing in kubernetes controllers
* Replace existing logging, metrics, or the events API
* Trace operations from all Kubernetes resource types in a generic manner (i.e. without manual instrumentation)
* Change metrics or logging (e.g. to support trace-metric correlation)
* Access control to tracing backends
* Add tracing to components outside kubernetes (e.g. etcd client library).

## Proposal

### User Stories

Since this feature is for diagnosing problems with the Kube-API Server, it is targeted at Cluster Operators and Cloud Vendors that manage kubernetes control-planes.

For the following use-cases, I can deploy an OpenTelemetry collector as a sidecar to the API Server.  I can use the API Server's `--opentelemetry-config-file` flag with the default URL to make the API Server send its spans to the sidecar collector.  Alternatively, I can point the API Server at an OpenTelemetry collector listening on a different port or URL if I need to.

#### Steady-State trace collection

As a cluster operator or cloud provider, I would like to collect traces for API requests to the API Server to help debug a variety of control-plane problems.  I can set the `SamplingRatePerMillion` in the configuration file to a non-zero number to have spans collected for a small fraction of requests.  Depending on the symptoms I need to debug, I can search span metadata to find a trace which displays the symptoms I am looking to debug.  Even for issues which occur non-deterministically, a low sampling rate is generally still enough to surface a representative trace over time.

#### On-Demand trace collection

As a cluster operator or cloud provider, I would like to collect a trace for a specific request to the API Server.  This will often happen when debugging a live problem.  In such cases, I don't want to change the `SamplingRatePerMillion` to collecting a high percentage of requests, which would be expensive and collect many things I don't care about.  I also don't want to restart the API Server, which may fix the problem I am trying to debug.  Instead, I can make sure the incoming request to the API Server is sampled.  The tooling to do this easily doesn't exist today, but could be added in the future.

For example, to trace a request to list nodes, with traceid=4bf92f3577b34da6a3ce929d0e0e4737, no parent span, and sampled=true:

```bash
kubectl proxy --port=8080 &
curl http://localhost:8080/api/v1/nodes -H "traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4737-0000000000000000-01"
```

### Tracing API Requests

We will wrap the API Server's http server and http clients with [otelhttp](https://github.com/open-telemetry/opentelemetry-go-contrib/tree/master/instrumentation/net/http/otelhttp) to get spans for incoming and outgoing http requests.  This generates spans for all sampled incoming requests and propagates context with all client requests.  For incoming requests, this would go below [WithRequestInfo](https://github.com/kubernetes/kubernetes/blob/9eb097c4b07ea59c674a69e19c1519f0d10f2fa8/staging/src/k8s.io/apiserver/pkg/server/config.go#L676) in the filter stack, as it must be after authentication and authorization, before the panic filter, and is closest in function to the WithRequestInfo filter.

Note that some clients of the API Server, such as webhooks, may make reentrant calls to the API Server.  To gain the full benefit of tracing, such clients should propagate context with requests back to the API Server.  One way to do this is to use the wrap the webhook's http server using otelhttp, and use the request's context when making requests to the API Server.

**Webhook Example**

Wrapping the http server, which ensures context is propagated from http headers to the requests context:
```golang
mux := http.NewServeMux()
handler := otelhttp.NewHandler(mux, "HandleAdmissionRequest")
```
Use the context from the request in reentrant requests:
```golang
ctx := req.Context()
client.CoreV1().Pods("").List(ctx, metav1.ListOptions{})
```

Note: Even though the admission controller uses the otelhttp handler wrapper, that does _not_ mean it will emit spans.  OpenTelemetry has a concept of an SDK, which manages the exporting of telemetry.  If no SDK is registered, the NoOp SDK is used, which only propagates context, and does not export spans.  In the webhook case in which no SDK is registered, the reentrant API call would appear to be a direct child of the original API call.  If the webhook registers an SDK and exports spans, there would be an additional span from the webhook between the original and reentrant API Server call.

Note: OpenTelemetry has a concept of ["Baggage"](https://github.com/open-telemetry/opentelemetry-specification/blob/master/specification/baggage/api.md#baggage-api), which is akin to annotations for propagated context.  If there is any additional metadata we would like to attach, and propagate along with a request, we can do that using Baggage.

### Exporting Spans

This KEP proposes the use of the [OpenTelemetry tracing framework](https://opentelemetry.io/) to create and export spans to configured backends.

The API Server will use the [OpenTelemetry exporter format](https://github.com/open-telemetry/opentelemetry-proto), and the [OTlp exporter](https://github.com/open-telemetry/opentelemetry-go/tree/master/exporters/otlp#opentelemetry-collector-go-exporter) which can export traces.  This format is easy to use with the [OpenTelemetry Collector](https://github.com/open-telemetry/opentelemetry-collector), which allows importing and configuring exporters for trace storage backends to be done out-of-tree in addition to other useful features.

### Running the OpenTelemetry Collector

The [OpenTelemetry Collector](https://github.com/open-telemetry/opentelemetry-collector) can be run as a sidecar, a daemonset, a deployment , or a combination in which the daemonset buffers telemetry and forwards to the deployment for aggregation (e.g. tail-base sampling) and routing to a telemetry backend.  To support these various setups, the API Server should be able to send traffic either to a local (on the control plane network) collector, or to a cluster service (on the cluster network).

### APIServer Configuration and EgressSelectors

The API Server controls where traffic is sent using an [EgressSelector](https://github.com/kubernetes/enhancements/blob/master/keps/sig-api-machinery/20190226-network-proxy.md), and has separate controls for `ControlPlane`, `Cluster`, and `Etcd` traffic.  As described above, we would like to support sending telemetry to a url using the `ControlPlane` egress.  To accomplish this, we will introduce a flag, `--opentelemetry-config-file`, that will point to the file that defines the opentelemetry exporter configuration.  That file will have the following format:

```golang
// +k8s:deepcopy-gen:interfaces=k8s.io/apimachinery/pkg/runtime.Object

// TracingConfiguration provides versioned configuration for tracing clients.
type TracingConfiguration struct {
  metav1.TypeMeta `json:",inline"`

  // +optional
  // URL of the collector that's running on the control-plane node.
  // the APIServer uses the egressType ControlPlane when sending data to the collector.
  // Defaults to localhost:4317
  URL *string `json:"url,omitempty" protobuf:"bytes,1,opt,name=url"`

  // +optional
  // SamplingRatePerMillion is the number of samples to collect per million spans.
  // Defaults to 0.
  SamplingRatePerMillion *int32 `json:"samplingRatePerMillion,omitempty" protobuf:"varint,2,opt,name=samplingRatePerMillion"`
}
```

If `--opentelemetry-config-file` is not specified, the API Server will not send any spans, even if incoming requests ask for sampling.

### Controlling use of the OpenTelemetry library

As the community found in the [Metrics Stability Framework KEP](https://github.com/kubernetes/enhancements/blob/master/keps/sig-instrumentation/1209-metrics-stability/kubernetes-control-plane-metrics-stability.md#kubernetes-control-plane-metrics-stability), having control over how the client libraries are used in kubernetes can enable maintainers to enforce policy and make broad improvements to the quality of telemetry.  To enable future improvements to tracing, we will restrict the direct use of the OpenTelemetry library within the kubernetes code base, and provide wrapped versions of functions we wish to expose in a utility library.

### Test Plan

We will e2e test this feature by deploying an OpenTelemetry Collector on the control-plane node, and configure it to export traces using the [stdout exporter](https://github.com/open-telemetry/opentelemetry-go/tree/master/exporters/stdout), which logs the spans in json format.  We can then verify that the logs contain our expected traces when making calls to the API Server.

## Graduation requirements

Alpha

- [] Implement tracing of incoming and outgoing http/grpc requests in the kube-apiserver
- [] Tests are in testgrid and linked in KEP

Beta

- [] Tracing 100% of requests does not break scalability tests (this does not necessarily mean trace backends can handle all the data).
- [] OpenTelemetry reaches GA
- [] Publish examples of how to use the OT Collector with kubernetes
- [] Allow time for feedback
- [] Revisit the format used to export spans.

GA

- [] Tracing e2e tests are promoted to conformance tests

## Production Readiness Review Questionnaire

### Feature Enablement and Rollback

* **How can this feature be enabled / disabled in a live cluster?**
  - [X] Feature gate (also fill in values in `kep.yaml`)
    - Feature gate name: APIServerTracing
    - Components depending on the feature gate: kube-apiserver
  - [X] Other
    - Describe the mechanism: Use specify a file using the `--opentelemetry-config-file` API Server flag.
    - Will enabling / disabling the feature require downtime of the control
      plane?  Yes, it will require restarting the API Server.
    - Will enabling / disabling the feature require downtime or reprovisioning
      of a node? (Do not assume `Dynamic Kubelet Config` feature is enabled). No.

* **Does enabling the feature change any default behavior?**
  No. The feature is disabled unlesss both the feature gate and `--opentelemetry-config-file` flag are set.  When the feature is enabled, it doesn't change behavior from the users' perspective; it only adds tracing telemetry based on API Server requests.

* **Can the feature be disabled once it has been enabled (i.e. can we roll back
  the enablement)?**
  Yes.

* **What happens if we reenable the feature if it was previously rolled back?**
  It will start sending traces again.  This will happen regardless of whether it was disabled by removing the `--opentelemetry-config-file` flag, or by disabling via feature gate.

* **Are there any tests for feature enablement/disablement?**
  Unit tests switching feature gates will be added.

### Rollout, Upgrade and Rollback Planning

_This section must be completed when targeting beta graduation to a release._

* **How can a rollout fail? Can it impact already running workloads?**
  Try to be as paranoid as possible - e.g., what if some components will restart
   mid-rollout?

* **What specific metrics should inform a rollback?**

* **Were upgrade and rollback tested? Was the upgrade->downgrade->upgrade path tested?**
  Describe manual testing that was done and the outcomes.
  Longer term, we may want to require automated upgrade/rollback tests, but we
  are missing a bunch of machinery and tooling and can't do that now.

* **Is the rollout accompanied by any deprecations and/or removals of features, APIs, 
fields of API types, flags, etc.?**
  Even if applying deprecation policies, they may still surprise some users.

### Monitoring Requirements

_This section must be completed when targeting beta graduation to a release._

* **How can an operator determine if the feature is in use by workloads?**
  Ideally, this should be a metric. Operations against the Kubernetes API (e.g.,
  checking if there are objects with field X set) may be a last resort. Avoid
  logs or events for this purpose.

* **What are the SLIs (Service Level Indicators) an operator can use to determine 
the health of the service?**
  - [ ] Metrics
    - Metric name:
    - [Optional] Aggregation method:
    - Components exposing the metric:
  - [ ] Other (treat as last resort)
    - Details:

* **What are the reasonable SLOs (Service Level Objectives) for the above SLIs?**
  At a high level, this usually will be in the form of "high percentile of SLI
  per day <= X". It's impossible to provide comprehensive guidance, but at the very
  high level (needs more precise definitions) those may be things like:
  - per-day percentage of API calls finishing with 5XX errors <= 1%
  - 99% percentile over day of absolute value from (job creation time minus expected
    job creation time) for cron job <= 10%
  - 99,9% of /health requests per day finish with 200 code

* **Are there any missing metrics that would be useful to have to improve observability 
of this feature?**
  Describe the metrics themselves and the reasons why they weren't added (e.g., cost,
  implementation difficulties, etc.).

### Dependencies

_This section must be completed when targeting beta graduation to a release._

* **Does this feature depend on any specific services running in the cluster?**
  Think about both cluster-level services (e.g. metrics-server) as well
  as node-level agents (e.g. specific version of CRI). Focus on external or
  optional services that are needed. For example, if this feature depends on
  a cloud provider API, or upon an external software-defined storage or network
  control plane.

  For each of these, fill in the following—thinking about running existing user workloads
  and creating new ones, as well as about cluster-level services (e.g. DNS):
  - [Dependency name]
    - Usage description:
      - Impact of its outage on the feature:
      - Impact of its degraded performance or high-error rates on the feature:


### Scalability

_For alpha, this section is encouraged: reviewers should consider these questions
and attempt to answer them._

_For beta, this section is required: reviewers must answer these questions._

_For GA, this section is required: approvers should be able to confirm the
previous answers based on experience in the field._

* **Will enabling / using this feature result in any new API calls?**
  This will not add any additional API calls.

* **Will enabling / using this feature result in introducing new API types?**
  This will introduce an API type for the configuration.  This is only for
  loading configuration, users cannot create these objects.

* **Will enabling / using this feature result in any new calls to the cloud 
provider?**
  Not directly.  Cloud providers could choose to send traces to their managed
  trace backends, but this requires them to set up a telemetry pipeline as
  described above.

* **Will enabling / using this feature result in increasing size or count of 
the existing API objects?**
  No.

* **Will enabling / using this feature result in increasing time taken by any 
operations covered by [existing SLIs/SLOs]?**
  It will increase API Server request latency by a negligible amount (<1 microsecond)
  for encoding and decoding the trace contex from headers, and recording spans
  in memory. Exporting spans is not in the critical path.

* **Will enabling / using this feature result in non-negligible increase of 
resource usage (CPU, RAM, disk, IO, ...) in any components?**
  The tracing client library has a small, in-memory cache for outgoing spans.

### Troubleshooting

The Troubleshooting section currently serves the `Playbook` role. We may consider
splitting it into a dedicated `Playbook` document (potentially with some monitoring
details). For now, we leave it here.

_This section must be completed when targeting beta graduation to a release._

* **How does this feature react if the API server and/or etcd is unavailable?**

* **What are other known failure modes?**
  For each of them, fill in the following information by copying the below template:
  - [Failure mode brief description]
    - Detection: How can it be detected via metrics? Stated another way:
      how can an operator troubleshoot without logging into a master or worker node?
    - Mitigations: What can be done to stop the bleeding, especially for already
      running user workloads?
    - Diagnostics: What are the useful log messages and their required logging
      levels that could help debug the issue?
      Not required until feature graduated to beta.
    - Testing: Are there any tests for failure mode? If not, describe why.

* **What steps should be taken if SLOs are not being met to determine the problem?**

[supported limits]: https://git.k8s.io/community//sig-scalability/configs-and-limits/thresholds.md
[existing SLIs/SLOs]: https://git.k8s.io/community/sig-scalability/slos/slos.md#kubernetes-slisslos

## Implementation History

* [Mutating admission webhook which injects trace context](https://github.com/Monkeyanator/mutating-trace-admission-controller)
* [Instrumentation of Kubernetes components](https://github.com/Monkeyanator/kubernetes/pull/15)
* [Instrumentation of Kubernetes components for 1/24/2019 community demo](https://github.com/kubernetes/kubernetes/compare/master...dashpole:tracing)
* KEP merged as provisional on 1/8/2020, including controller tracing
* KEP scoped down to only API Server traces on 5/1/2020
* Updated PRR section 2/8/2021

## Alternatives considered

### Introducing a new EgressSelector type

Instead of a configuration file to choose between a url on the `ControlPlane` network, or a service on the `Cluster` network, we considered introducing a new `OpenTelemetry` egress type, which could be configured separately.  However, we aren't actually introducing a new destination for traffic, so it is more conventional to make use of existing egress types.  We will also likely want to add additional configuration for the OpenTelemetry client in the future.

### Other OpenTelemetry Exporters

This KEP suggests that we utilize the OpenTelemetry exporter format in all components.  Alternative options include:

1. Add configuration for many exporters in-tree by vendoring multiple "supported" exporters. These exporters are the only compatible backends for tracing in kubernetes.
  a. This places the kubernetes community in the position of curating supported tracing backends
2. Support *both* a curated set of in-tree exporters, and the collector exporter