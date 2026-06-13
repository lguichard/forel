import { Monitor, Moon, Sun, X } from "lucide-react";
import { Theme, useSettings } from "../store/settings";

const THEME_OPTIONS: { value: Theme; label: string; icon: typeof Sun }[] = [
  { value: "system", label: "System", icon: Monitor },
  { value: "light", label: "Light", icon: Sun },
  { value: "dark", label: "Dark", icon: Moon },
];

export default function Settings({ onClose }: { onClose: () => void }) {
  const { theme, setTheme } = useSettings();

  return (
    <div
      className="editor-overlay"
      onClick={(e) => e.target === e.currentTarget && onClose()}
    >
      <div className="settings-panel">
        <header className="settings-header">
          <h2 className="settings-title">Settings</h2>
          <button className="editor-close" onClick={onClose} title="Close">
            <X size={16} />
          </button>
        </header>

        <section className="settings-section">
          <div className="settings-row">
            <div className="settings-label">
              <span className="settings-label-title">Appearance</span>
              <span className="settings-label-sub">
                Match the system or pick a fixed theme.
              </span>
            </div>
            <div className="segmented">
              {THEME_OPTIONS.map(({ value, label, icon: Icon }) => (
                <button
                  key={value}
                  className={`segmented-option${theme === value ? " active" : ""}`}
                  onClick={() => setTheme(value)}
                  title={label}
                >
                  <Icon size={13} />
                  <span>{label}</span>
                </button>
              ))}
            </div>
          </div>
        </section>

        <section className="settings-section">
          <div className="settings-about">
            <span className="settings-about-name">Forel</span>
            <span className="settings-about-version">Version 0.1.0 · alpha</span>
            <span className="settings-about-desc">
              Open-source file automation for macOS.
            </span>
          </div>
        </section>
      </div>
    </div>
  );
}
