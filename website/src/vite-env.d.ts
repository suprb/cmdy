/// <reference types="vite/client" />

interface CmdyMarketplaceSnapshot {
  api?: number;
  name?: string;
  featured?: unknown[];
  entries?: unknown[];
}

interface Window {
  CMDY_MARKETPLACE_SNAPSHOT?: CmdyMarketplaceSnapshot;
}
