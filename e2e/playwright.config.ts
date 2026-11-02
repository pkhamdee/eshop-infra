import { defineConfig, devices } from '@playwright/test'
import { baseURL, gatewayHost } from './environment'

// Seam 4: the definition-of-done demo in a real browser against a deployed environment (never on every CI run).
// npm run e2e                                          -> https://eshop.localhost (eshop-dev)
// E2E_BASE_URL=https://prod.eshop.localhost npm run e2e -> eshop-prod (post-release smoke test)
export default defineConfig({
  testDir: './tests',
  globalSetup: './global-setup.ts',
  // Real waits: Credit Decision (≤ 60 s), sync-master cycles (30 s each way), an Auction closing ~2 min ahead.
  timeout: 6 * 60_000,
  expect: { timeout: 15_000 },
  // Two projects × three tests on two workers: about twice the wall time of one size (~7–8 min). Each test makes
  // its own Customers, Contract, Auction and Lot (tests/steps.ts), so tests running side by side never share data.
  fullyParallel: true,
  workers: 2,
  // In the pipeline (CI is set), a failed test runs once more: a pass on the retry counts, but the report keeps the
  // first attempt's failure, and the run summary names the test (e2e.yml reads results.json). Locally, no retry.
  retries: process.env.CI ? 1 : 0,
  forbidOnly: !!process.env.CI,
  reporter: [
    ['list'],
    ['html', { open: 'never' }],
    ...(process.env.CI ? [['json', { outputFile: 'results.json' }] as const] : []),
  ],
  use: {
    baseURL,
    // The local cluster's certificate comes from a self-signed CA.
    ignoreHTTPSErrors: true,
    // ...but Chromium still refuses to register a service worker (#59) on an untrusted origin without this flag.
    // In the cluster, the eShop hostnames go to the Gateway (environment.ts); the URL, Host header and TLS name
    // stay eshop.localhost. Requests made outside the browser (page.request, global-setup) resolve them through
    // /etc/hosts instead, which the workflow points at the Gateway.
    launchOptions: {
      args: [
        '--ignore-certificate-errors',
        ...(gatewayHost
          ? [`--host-resolver-rules=MAP eshop.localhost ${gatewayHost}, MAP *.eshop.localhost ${gatewayHost}`]
          : []),
      ],
    },
    locale: 'th-TH',
    timezoneId: 'Asia/Bangkok',
    // Traces record request bodies (the Staff sign-in) and SMS codes: keep them local, never in CI artifacts.
    actionTimeout: 30_000,
    navigationTimeout: 30_000,
    trace: process.env.CI ? 'off' : 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
  // The whole demo at both sizes (#51), in Chromium. Contexts a test opens itself (Staff, the SMS inbox, the
  // Enterprise admin tool) inherit the project's size. Pixel 7, not an iPhone preset: those need WebKit.
  projects: [
    { name: 'phone', use: { ...devices['Pixel 7'], viewport: { width: 390, height: 844 } } },
    { name: 'desktop', use: { ...devices['Desktop Chrome'], viewport: { width: 1280, height: 800 } } },
  ],
})
