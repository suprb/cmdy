import type { ReactNode } from "react";

interface SiteShellProps {
  children: ReactNode;
  page: "home" | "docs" | "marketplace";
}

export function SiteShell({ children, page }: SiteShellProps) {
  return (
    <>
      <a className="skip-link" href="#main-content">Skip to content</a>
      <header className="site-header">
        <nav>
          <div className="wrap">
            <a className="brand" href="./" aria-label="cmdy home">
              <img src="./cmdy-wordmark.svg" alt="cmdy" />
            </a>
            <span className="nav-links">
              <a className={page === "docs" ? "active" : ""} href="./docs.html" aria-current={page === "docs" ? "page" : undefined}>Docs</a>
              <a className="btn solid" href="https://github.com/suprb/cmdy/releases/latest">Download</a>
            </span>
          </div>
        </nav>
      </header>
      <main id="main-content">{children}</main>
      <footer className="site-footer">
        <div className="wrap">
          <a className="footer-brand" href="./" aria-label="cmdy home"><img src="./cmdy-wordmark.svg" alt="cmdy" /></a>
          <a href="./docs.html">Docs</a>
          <a href="./marketplace.html">Marketplace</a>
          <a href="https://github.com/suprb/cmdy">Source</a>
          <span className="c">© 2026 cmdy</span>
        </div>
      </footer>
    </>
  );
}
