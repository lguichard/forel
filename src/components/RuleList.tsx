import { Eye, Play, Plus, Trash2, X } from "lucide-react";
import { useState } from "react";
import { useForelStore } from "../store";
import { PreviewResult, Rule } from "../types";
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
    previewRules,
  } = useForelStore();

  const [editingRule, setEditingRule] = useState<Rule | null>(null);
  const [runResult, setRunResult] = useState<string[] | null>(null);
  const [previewResult, setPreviewResult] = useState<PreviewResult | null>(null);
  const [previewing, setPreviewing] = useState(false);

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

  const handlePreview = async () => {
    if (!selectedFolderId) return;
    setPreviewing(true);
    try {
      const result = await previewRules(selectedFolderId);
      setPreviewResult(result);
    } finally {
      setPreviewing(false);
    }
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
          <button
            className="btn btn-secondary"
            onClick={handlePreview}
            disabled={previewing}
            title="Preview what rules would do"
          >
            <Eye size={13} /> {previewing ? "Previewing…" : "Preview"}
          </button>
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

      {previewResult && (
        <section className="preview-panel">
          <div className="preview-header">
            <div>
              <h3 className="preview-title">Preview</h3>
              <p className="preview-summary">
                {previewResult.files_scanned} file
                {previewResult.files_scanned !== 1 ? "s" : ""} scanned,{" "}
                {previewResult.matches.length} file
                {previewResult.matches.length !== 1 ? "s" : ""} with matching rules.
              </p>
            </div>
            <button
              className="preview-close"
              type="button"
              onClick={() => setPreviewResult(null)}
              title="Close preview"
            >
              <X size={13} />
            </button>
          </div>

          {previewResult.matches.length === 0 ? (
            <div className="preview-empty">No files would be changed.</div>
          ) : (
            <div className="preview-list">
              {previewResult.matches.map((file) => (
                <article className="preview-file" key={file.path}>
                  <div className="preview-file-name">{file.name || file.path}</div>
                  <div className="preview-file-path">{file.path}</div>
                  <div className="preview-rules">
                    {file.rules.map((rule) => (
                      <div className="preview-rule" key={rule.rule_id}>
                        <div className="preview-rule-name">{rule.rule_name}</div>
                        {rule.actions.length === 0 ? (
                          <div className="preview-action preview-action-empty">
                            No actions configured.
                          </div>
                        ) : (
                          <ul className="preview-actions">
                            {rule.actions.map((action, index) => (
                              <li className="preview-action" key={`${rule.rule_id}-${index}`}>
                                {action}
                              </li>
                            ))}
                          </ul>
                        )}
                      </div>
                    ))}
                  </div>
                </article>
              ))}
            </div>
          )}
        </section>
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
