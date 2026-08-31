import { DocsPage } from "./pages/DocsPage";
import { HomePage } from "./pages/HomePage";
import { MarketplacePage } from "./pages/MarketplacePage";
import { SiteShell } from "./components/SiteShell";

type Page = "home" | "docs" | "marketplace";

export function App() {
  const page = (document.body.dataset.page ?? "home") as Page;

  const content = page === "docs"
    ? <DocsPage />
    : page === "marketplace"
      ? <MarketplacePage />
      : <HomePage />;

  return (
    <div className="cmdy-site theme-light">
      <SiteShell page={page}>
        {content}
      </SiteShell>
    </div>
  );
}
