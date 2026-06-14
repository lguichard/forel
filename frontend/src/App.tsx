import { Settings as SettingsIcon } from "lucide-react";
import { useEffect, useState } from "react";
import RuleList from "./components/RuleList";
import Settings from "./components/Settings";
import Sidebar from "./components/Sidebar";
import { useForelStore } from "./store";
import "./store/settings"; // applies the persisted theme on load
import "./App.css";

export default function App() {
  const fetchFolders = useForelStore((s) => s.fetchFolders);
  const [showSettings, setShowSettings] = useState(false);

  useEffect(() => {
    void fetchFolders();
  }, [fetchFolders]);

  // ⌘, opens Settings, like a native macOS app.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.metaKey && e.key === ",") {
        e.preventDefault();
        setShowSettings(true);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  return (
    <div className="app">
      <div className="titlebar">
        <div className="titlebar-brand">
          <img className="titlebar-icon" src="/forel-icon.png" alt="" />
          <span className="titlebar-title">Forel</span>
        </div>
        <button
          className="titlebar-btn"
          onClick={() => setShowSettings(true)}
          title="Settings (⌘,)"
        >
          <SettingsIcon size={15} />
        </button>
      </div>

      <div className="layout">
        <Sidebar />
        <RuleList />
      </div>

      {showSettings && <Settings onClose={() => setShowSettings(false)} />}
    </div>
  );
}
