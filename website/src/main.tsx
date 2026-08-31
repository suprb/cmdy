import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import "./styles/tokens.css";
import "./styles/sacred.css";
import "./styles/site.css";
import "./styles/static-docs.css";
import "./styles/react-port.css";

const root = document.getElementById("root");
if (!root) throw new Error("cmdy site root is missing");

createRoot(root).render(
  <StrictMode>
    <App />
  </StrictMode>
);
