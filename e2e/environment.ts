// Which deployed environment the smoke test runs against. E2E_BASE_URL picks it (default: eshop-dev);
// the environment name (dev | qa | prod) selects the mock Enterprise System database and the SOPS Staff Secret.
export const baseURL = (process.env.E2E_BASE_URL ?? 'https://eshop.localhost').replace(/\/+$/, '')

type Environment = 'dev' | 'qa' | 'prod'

// qa.eshop.localhost -> qa, prod.eshop.localhost -> prod, anything else (eshop.localhost) -> dev. E2E_ENV overrides.
function fromHostname(hostname: string): Environment {
  if (hostname.startsWith('prod.')) return 'prod'
  if (hostname.startsWith('qa.')) return 'qa'
  return 'dev'
}

export const environment: Environment =
  (process.env.E2E_ENV as Environment | undefined) ?? fromHostname(new URL(baseURL).hostname)

// thirdparty-mock (SMS inbox, Enterprise System admin tool) is one shared deployment routed on eshop.localhost
// only, so the test reads it there whichever environment it runs against. E2E_MOCK_URL overrides it.
export const mockBaseURL = (process.env.E2E_MOCK_URL ?? 'https://eshop.localhost').replace(/\/+$/, '')

// On the cluster's runner (.github/workflows/e2e.yml), the test runs in a pod, where Kubernetes sets
// KUBERNETES_SERVICE_HOST. There the Staff account comes from the environment's Secret (kubectl, the runner's own
// service account) instead of SOPS, and the eShop hostnames must be sent to the Gateway: Chromium answers every
// *.localhost name with loopback itself, which in a pod is the pod. E2E_GATEWAY_HOST overrides where they go.
export const inCluster = !!process.env.KUBERNETES_SERVICE_HOST

export const gatewayHost = process.env.E2E_GATEWAY_HOST ?? (inCluster ? 'traefik.kube-system.svc.cluster.local' : undefined)
