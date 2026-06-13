import { Play, Plus, Trash2 } from "lucide-react";
import { useState } from "react";
import { useForelStore } from "../store";
import { Rule } from "../types";
import RuleEditor from "./RuleEditor";

export default function RuleList() {
  const {
    selectedFolderId,
    folders,
    rules,
    loading,
    createRule,
    deleteRule,
    toggleRule,
    runRulesNow,
  } = useForelStore();

  const [editingRule, setEditingRule] = useState<Rule | null>(null);
  const [runResult, setRunResult] = useState<string[] | null>(null);

  const selectedFolder = folders.find((f) => f.id === selectedFolderId);

  const handleAdd = async () => {
    if (!selectedFolderId) return;
    const rule = await createRule(selectedFolderId, "New Rule");
    setEditingRule(rule);
  };

  const handleRunNow = async () => {
    if (!selectedFolderId) return;
    const matched = await runRulesNow(selectedFolderId);
    setRunResult(matched);
    setTimeout(() => setRunResult(null), 4000);
  };

  if (!selectedFolderId) {
    return (
      <main className="rule-list-empty">
        <p>Select a folder on the left to manage its rules.</p>
      </main>
    );
  }

  return (
    <main className="rule-list">
      <header className="rule-list-header">
        <div>
          <h2 className="rule-list-title">{selectedFolder?.path.split("/").pop()}</h2>
          <p className="rule-list-subtitle">{selectedFolder?.path}</p>
        </div>
        <div className="rule-list-actions">
          <button className="btn btn-secondary" onClick={handleRunNow} title="Run rules now">
            <Play size={13} /> Run now
          </button>
          <button className="btn btn-primary" onClick={handleAdd}>
            <Plus size={13} /> Add Rule
          </button>
        </div>
      </header>

      {runResult !== null && (
        <div className="run-result">
          {runResult.length === 0
            ? "No rules matched. All files are up to date."
            : `Matched: ${runResult.join(", ")}`}
        </div>
      )}

      {loading ? (
        <div className="rule-loading">Loading…</div>
      ) : rules.length === 0 ? (
        <div className="rule-empty">
          No rules yet — click <strong>Add Rule</strong> to create one.
        </div>
      ) : (
        <ul className="rules">
          {rules.map((rule) => (
            <RuleRow
              key={rule.id}
              rule={rule}
              onEdit={() => setEditingRule(rule)}
              onToggle={(enabled) => toggleRule(rule.id, enabled)}
              onDelete={() => deleteRule(rule.id)}
            />
          ))}
        </ul>
      )}

      {editingRule && (
        <RuleEditor rule={editingRule} onClose={() => setEditingRule(null)} />
      )}
    </main>
  );
}

function RuleRow({
  rule,
  onEdit,
  onToggle,
  onDelete,
}: {
  rule: Rule;
  onEdit: () => void;
  onToggle: (v: boolean) => void;
  onDelete: () => void;
}) {
  return (
    <li className={`rule-row ${rule.enabled ? "" : "rule-disabled"}`}>
      <label className="switch" title={rule.enabled ? "Enabled" : "Disabled"}>
        <input
          type="checkbox"
          checked={rule.enabled}
          onChange={(e) => onToggle(e.target.checked)}
        />
        <span className="switch-slider" />
      </label>
      <div className="rule-info" onClick={onEdit}>
        <span className="rule-name">{rule.name}</span>
        <span className="rule-summary">
          {rule.conditions.length} condition{rule.conditions.length !== 1 ? "s" : ""},{" "}
          {rule.actions.length} action{rule.actions.length !== 1 ? "s" : ""}
        </span>
      </div>
      <button className="rule-delete" onClick={onDelete} title="Delete rule">
        <Trash2 size={13} />
      </button>
    </li>
  );
}
