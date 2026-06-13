import { useEffect } from "react";
import RuleList from "./components/RuleList";
import Sidebar from "./components/Sidebar";
import { useForelStore } from "./store";
import "./App.css";

export default function App() {
  const fetchFolders = useForelStore((s) => s.fetchFolders);

  useEffect(() => {
    fetchFolders();
  }, [fetchFolders]);

  return (
    <div className="app">
      <div className="titlebar" data-tauri-drag-region />
      <div className="layout">
        <Sidebar />
        <RuleList />
      </div>
    </div>
  );
}
