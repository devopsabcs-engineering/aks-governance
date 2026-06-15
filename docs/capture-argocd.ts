/**
 * capture-argocd.ts
 *
 * Best-effort screenshot capture for the AKS governance PoC. Produces two groups
 * of screenshots:
 *
 *   1. ArgoCD UI - the Applications view and per-application sync status, proving
 *      the GitOps fan-out (governance policies synced to each workload cluster).
 *   2. Azure portal (optional) - the management AKS cluster blades (Overview +
 *      Cluster configuration), reusing the persisted portal session.
 *
 * Auth model (matches the aks-fleet-manager sibling):
 *   - Azure portal: log in once interactively (completing MFA by hand) and
 *     persist browser state, then reuse it here headlessly:
 *       npx playwright codegen https://portal.azure.com --save-storage=storage_state.json
 *     storage_state.json contains cookies/tokens that can impersonate the user.
 *     Never commit it - keep it git-ignored and treat it as a secret.
 *   - ArgoCD: when the persisted session does not cover ArgoCD, this script
 *     performs a form login with ARGOCD_USERNAME / ARGOCD_PASSWORD (the initial
 *     admin password is 'argocd admin initial-password -n argocd').
 *
 * Run via: npm run capture   (-> tsx capture-argocd.ts), from the docs/ folder,
 * or directly: npx tsx capture-argocd.ts
 */
import { chromium, Browser, BrowserContext, Page } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

// --- Config (env-driven; never hard-code secrets) ---
const ARGOCD_URL = process.env.ARGOCD_URL ?? 'https://localhost:8080';
const ARGOCD_USERNAME = process.env.ARGOCD_USERNAME ?? 'admin';
const ARGOCD_PASSWORD = process.env.ARGOCD_PASSWORD; // optional when session is reused
// ArgoCD self-signed certs are common on a PoC LoadBalancer/port-forward endpoint.
const ARGOCD_INSECURE = (process.env.ARGOCD_INSECURE ?? 'true').toLowerCase() !== 'false';
const ARGOCD_APP = process.env.ARGOCD_APP; // optional: a specific Application to detail-screenshot

const SUB = process.env.AZ_SUBSCRIPTION_ID;
const RG = process.env.AZ_RESOURCE_GROUP;
const MGMT = process.env.AZ_MGMT_CLUSTER; // management AKS cluster name
const TENANT = process.env.AZ_TENANT_ID; // optional but recommended for deep links

const STORAGE = process.env.PW_STORAGE_STATE ?? 'storage_state.json';
const OUT = process.env.SCREENSHOT_DIR ?? 'screenshots';

// Build a portal deep link to a specific AKS managed-cluster blade.
// The #@{tenant} segment is optional; including it avoids a tenant picker.
function aksBlade(menu: string): string {
  const tenantSeg = TENANT ? `@${TENANT}/` : '';
  const resourceId =
    `/subscriptions/${SUB}/resourceGroups/${RG}` +
    `/providers/Microsoft.ContainerService/managedClusters/${MGMT}`;
  return `https://portal.azure.com/#${tenantSeg}resource${resourceId}/${menu}`;
}

async function settle(page: Page, waitText: RegExp, timeoutMs = 30_000): Promise<void> {
  // Both the portal and the ArgoCD UI are SPAs; wait on real UI, not networkidle.
  await page.waitForLoadState('domcontentloaded');
  try {
    await page.getByText(waitText).first().waitFor({ state: 'visible', timeout: timeoutMs });
  } catch {
    // Fallback: give late-loading content a moment.
    await page.waitForTimeout(4_000);
  }
  // Small settle for charts/tiles to paint.
  await page.waitForTimeout(2_000);
}

function maskFor(page: Page) {
  // Mask anything sensitive (subscription chips, directory, emails).
  const masks = [page.locator('[aria-label*="Directory"]'), page.getByText(/@[\w.-]+\.[a-z]{2,}/i)];
  if (SUB) {
    masks.unshift(page.getByText(SUB));
  }
  return masks;
}

// --- ArgoCD UI capture ---
async function isArgoLoginPage(page: Page): Promise<boolean> {
  if (/\/login/i.test(page.url())) {
    return true;
  }
  const pwd = page.locator('input[type="password"]');
  return (await pwd.count()) > 0;
}

async function argoLogin(page: Page): Promise<void> {
  if (!(await isArgoLoginPage(page))) {
    return; // session already authenticated
  }
  if (!ARGOCD_PASSWORD) {
    throw new Error(
      'ArgoCD login required but ARGOCD_PASSWORD is not set. Get it with: ' +
        'argocd admin initial-password -n argocd',
    );
  }
  await page.locator('input[name="username"], input[type="text"]').first().fill(ARGOCD_USERNAME);
  await page.locator('input[name="password"], input[type="password"]').first().fill(ARGOCD_PASSWORD);
  await page.getByRole('button', { name: /sign in|log in|login/i }).first().click();
  await page.waitForTimeout(3_000);
}

async function captureArgoCd(browser: Browser): Promise<void> {
  const context: BrowserContext = await browser.newContext({
    storageState: fs.existsSync(STORAGE) ? STORAGE : undefined,
    viewport: { width: 1920, height: 1080 },
    deviceScaleFactor: 2,
    ignoreHTTPSErrors: ARGOCD_INSECURE,
  });
  const page: Page = await context.newPage();
  try {
    // Applications list view.
    await page.goto(`${ARGOCD_URL}/applications`, { waitUntil: 'domcontentloaded' });
    await argoLogin(page);
    await settle(page, /Applications|Sync|Healthy|OutOfSync|Synced/i);
    let file = path.join(OUT, '01-argocd-applications.png');
    await page.screenshot({ path: file, fullPage: true, mask: maskFor(page), maskColor: '#1f2937' });
    console.log(`captured ${file}`);

    // Optional: drill into a single Application to show resource tree + sync status.
    if (ARGOCD_APP) {
      try {
        await page.goto(`${ARGOCD_URL}/applications/${ARGOCD_APP}`, { waitUntil: 'domcontentloaded' });
        await argoLogin(page);
        await settle(page, /Sync Status|Health|Current Sync|Last Sync|App Details/i);
        file = path.join(OUT, `02-argocd-app-${ARGOCD_APP}.png`);
        await page.screenshot({ path: file, fullPage: true, mask: maskFor(page), maskColor: '#1f2937' });
        console.log(`captured ${file}`);
      } catch (e) {
        console.warn(`argocd app detail capture skipped: ${(e as Error).message}`);
      }
    }
  } finally {
    await context.close();
  }
}

// --- Azure portal AKS capture (optional) ---
async function capturePortal(browser: Browser): Promise<void> {
  if (!SUB || !RG || !MGMT) {
    console.warn('Skipping portal AKS capture: set AZ_SUBSCRIPTION_ID, AZ_RESOURCE_GROUP, AZ_MGMT_CLUSTER.');
    return;
  }
  if (!fs.existsSync(STORAGE)) {
    console.warn(`Skipping portal AKS capture: missing ${STORAGE}.`);
    return;
  }

  const context: BrowserContext = await browser.newContext({
    storageState: STORAGE,
    viewport: { width: 1920, height: 1080 },
    deviceScaleFactor: 2,
  });
  const page: Page = await context.newPage();

  const blades: { name: string; menu: string; waitText: RegExp }[] = [
    { name: '03-mgmt-aks-overview', menu: 'overview', waitText: /Overview|Essentials|Kubernetes version/i },
    { name: '04-mgmt-aks-config', menu: 'clusterConfiguration', waitText: /Cluster configuration|Security|Workload identity|OIDC/i },
  ];

  try {
    for (const blade of blades) {
      const url = aksBlade(blade.menu);
      await page.goto(url, { waitUntil: 'domcontentloaded' });
      if (/login\.microsoftonline\.com|\/oauth2\//.test(page.url())) {
        throw new Error(
          'storage_state.json appears expired - re-run: ' +
            'npx playwright codegen https://portal.azure.com --save-storage=storage_state.json',
        );
      }
      await settle(page, blade.waitText);
      const file = path.join(OUT, `${blade.name}.png`);
      await page.screenshot({ path: file, fullPage: true, mask: maskFor(page), maskColor: '#1f2937' });
      console.log(`captured ${file}`);
    }
  } catch (e) {
    console.warn(`portal AKS capture skipped: ${(e as Error).message}`);
  } finally {
    await context.close();
  }
}

async function main(): Promise<void> {
  fs.mkdirSync(OUT, { recursive: true });
  const browser: Browser = await chromium.launch({ headless: true });
  try {
    await captureArgoCd(browser);
    await capturePortal(browser);
  } finally {
    await browser.close();
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
