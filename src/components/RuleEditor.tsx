import { invoke } from "@tauri-apps/api/core";
import { open } from "@tauri-apps/plugin-dialog";
import { Check, Minus, Plus, X } from "lucide-react";
import { useEffect, useState } from "react";
import { useForelStore } from "../store";
import {
  ACTION_KIND_LABELS,
  Action,
  ActionKind,
  CONDITION_KIND_LABELS,
  Condition,
  ConditionKind,
  ConditionMatch,
  OPERATOR_LABELS,
  Operator,
  Rule,
} from "../types";
import { v4 as uuidv4 } from "uuid";

interface Props {
  rule: Rule;
  onClose: () => void;
}

const STRING_OPERATORS: Operator[] = [
  "is", "is_not", "contains", "does_not_contain",
  "starts_with", "ends_with", "matches_regex",
];
const NUMBER_OPERATORS: Operator[] = ["is", "is_not", "greater_than", "less_than"];
const DATE_OPERATORS: Operator[] = ["is", "is_not", "before", "after"];

function operatorsFor(kind: ConditionKind): Operator[] {
  if (kind === "size_bytes") return NUMBER_OPERATORS;
  if (kind === "date_created" || kind === "date_modified") return DATE_OPERATORS;
  return STRING_OPERATORS;
}

export default function RuleEditor({ rule, onClose }: Props) {
  const { updateRule } = useForelStore();
  const [draft, setDraft] = useState<Rule>(structuredClone(rule));

  const save = async () => {
    await updateRule(draft);
    onClose();
  };

  const addCondition = () => {
    const cond: Condition = {
      id: uuidv4(),
      rule_id: draft.id,
      kind: "name",
      operator: "contains",
      value: "",
    };
    setDraft((d) => ({ ...d, conditions: [...d.conditions, cond] }));
  };

  const updateCondition = (index: number, patch: Partial<Condition>) => {
    setDraft((d) => {
      const conditions = d.conditions.map((c, i) =>
        i === index ? { ...c, ...patch } : c
      );
      return { ...d, conditions };
    });
  };

  const removeCondition = (index: number) => {
    setDraft((d) => ({
      ...d,
      conditions: d.conditions.filter((_, i) => i !== index),
    }));
  };

  const addAction = () => {
    const act: Action = {
      id: uuidv4(),
      rule_id: draft.id,
      kind: "move_to_folder",
      params: { destination: "" },
      position: draft.actions.length,
    };
    setDraft((d) => ({ ...d, actions: [...d.actions, act] }));
  };

  const updateAction = (index: number, patch: Partial<Action>) => {
    setDraft((d) => {
      const actions = d.actions.map((a, i) =>
        i === index ? { ...a, ...patch } : a
      );
      return { ...d, actions };
    });
  };

  const removeAction = (index: number) => {
    setDraft((d) => ({
      ...d,
      actions: d.actions.filter((_, i) => i !== index),
    }));
  };

  return (
    <div className="editor-overlay" onClick={(e) => e.target === e.currentTarget && onClose()}>
      <div className="editor-panel">
        <div className="editor-header">
          <input
            className="editor-title-input"
            value={draft.name}
            onChange={(e) => setDraft((d) => ({ ...d, name: e.target.value }))}
          />
          <button className="editor-close" onClick={onClose}>
            <X size={16} />
          </button>
        </div>

        {/* Conditions */}
        <section className="editor-section">
          <div className="editor-section-header">
            <span>
              Match{" "}
              <select
                value={draft.condition_match}
                onChange={(e) =>
                  setDraft((d) => ({
                    ...d,
                    condition_match: e.target.value as ConditionMatch,
                  }))
                }
              >
                <option value="all">all</option>
                <option value="any">any</option>
              </select>{" "}
              of the following conditions:
            </span>
            <button className="section-add-btn" onClick={addCondition}>
              <Plus size={12} />
            </button>
          </div>

          {draft.conditions.map((cond, i) => (
            <ConditionRow
              key={cond.id}
              condition={cond}
              onChange={(patch) => updateCondition(i, patch)}
              onRemove={() => removeCondition(i)}
            />
          ))}

          {draft.conditions.length === 0 && (
            <p className="editor-empty">No conditions — rule will never match.</p>
          )}
        </section>

        {/* Actions */}
        <section className="editor-section">
          <div className="editor-section-header">
            <span>Do the following:</span>
            <button className="section-add-btn" onClick={addAction}>
              <Plus size={12} />
            </button>
          </div>

          {draft.actions.map((act, i) => (
            <ActionRow
              key={act.id}
              action={act}
              onChange={(patch) => updateAction(i, patch)}
              onRemove={() => removeAction(i)}
            />
          ))}

          {draft.actions.length === 0 && (
            <p className="editor-empty">No actions defined.</p>
          )}
        </section>

        <div className="editor-footer">
          <button className="btn btn-secondary" onClick={onClose}>
            Cancel
          </button>
          <button className="btn btn-primary" onClick={save}>
            Save
          </button>
        </div>
      </div>
    </div>
  );
}

// ---------- Condition row ----------

function ConditionRow({
  condition,
  onChange,
  onRemove,
}: {
  condition: Condition;
  onChange: (p: Partial<Condition>) => void;
  onRemove: () => void;
}) {
  const ops = operatorsFor(condition.kind);
  const currentOp = ops.includes(condition.operator) ? condition.operator : ops[0];

  return (
    <div className="condition-row">
      <select
        value={condition.kind}
        onChange={(e) =>
          onChange({ kind: e.target.value as ConditionKind, operator: ops[0], value: "" })
        }
      >
        {(Object.keys(CONDITION_KIND_LABELS) as ConditionKind[]).map((k) => (
          <option key={k} value={k}>
            {CONDITION_KIND_LABELS[k]}
          </option>
        ))}
      </select>

      <select
        value={currentOp}
        onChange={(e) => onChange({ operator: e.target.value as Operator })}
      >
        {ops.map((op) => (
          <option key={op} value={op}>
            {OPERATOR_LABELS[op]}
          </option>
        ))}
      </select>

      <input
        className="condition-value"
        value={condition.value}
        placeholder="value"
        onChange={(e) => onChange({ value: e.target.value })}
      />

      <button className="row-remove" onClick={onRemove}>
        <Minus size={12} />
      </button>
    </div>
  );
}

// ---------- Action row ----------

function ActionRow({
  action,
  onChange,
  onRemove,
}: {
  action: Action;
  onChange: (p: Partial<Action>) => void;
  onRemove: () => void;
}) {
  const needsFolder =
    action.kind === "move_to_folder" || action.kind === "copy_to_folder";
  const needsPattern = action.kind === "rename";
  const needsTag = action.kind === "add_tag" || action.kind === "remove_tag";
  const needsScript = action.kind === "run_script";

  const pickFolder = async () => {
    const selected = await open({ directory: true, multiple: false });
    if (typeof selected === "string") {
      onChange({ params: { ...action.params, destination: selected } });
    }
  };

  return (
    <div className="action-row">
      <select
        value={action.kind}
        onChange={(e) => onChange({ kind: e.target.value as ActionKind, params: {} })}
      >
        {(Object.keys(ACTION_KIND_LABELS) as ActionKind[]).map((k) => (
          <option key={k} value={k}>
            {ACTION_KIND_LABELS[k]}
          </option>
        ))}
      </select>

      {needsFolder && (
        <div className="action-folder-picker">
          <input
            className="action-value"
            value={action.params.destination ?? ""}
            placeholder="Destination folder"
            readOnly
          />
          <button className="btn btn-secondary btn-sm" onClick={pickFolder}>
            Choose…
          </button>
        </div>
      )}

      {needsPattern && (
        <input
          className="action-value"
          value={action.params.pattern ?? ""}
          placeholder="{name} - {date_modified}"
          onChange={(e) =>
            onChange({ params: { ...action.params, pattern: e.target.value } })
          }
        />
      )}

      {needsTag && (
        <MacTagPicker
          value={action.params.tag ?? ""}
          onChange={(tag) => onChange({ params: { ...action.params, tag } })}
        />
      )}

      {needsScript && (
        <textarea
          className="action-script"
          value={action.params.script ?? ""}
          placeholder="#!/bin/bash&#10;echo $FOREL_FILE"
          onChange={(e) =>
            onChange({ params: { ...action.params, script: e.target.value } })
          }
        />
      )}

      <button className="row-remove" onClick={onRemove}>
        <Minus size={12} />
      </button>
    </div>
  );
}

// ---------- macOS tag picker ----------

const MACOS_TAG_COLORS: Record<string, string> = {
  Red: "#FF3B30",
  Orange: "#FF9500",
  Yellow: "#FFCC00",
  Green: "#34C759",
  Blue: "#007AFF",
  Purple: "#AF52DE",
  Gray: "#8E8E93",
};

function MacTagPicker({
  value,
  onChange,
}: {
  value: string;
  onChange: (tag: string) => void;
}) {
  const [tags, setTags] = useState<string[]>(Object.keys(MACOS_TAG_COLORS));

  useEffect(() => {
    invoke<string[]>("get_macos_tags")
      .then(setTags)
      .catch(() => {}); // fallback: keep the 7 system colours
  }, []);

  return (
    <div className="tag-picker">
      {tags.map((tag) => {
        const color = MACOS_TAG_COLORS[tag] ?? "#8E8E93";
        const selected = value === tag;
        return (
          <button
            key={tag}
            className={`tag-dot${selected ? " tag-dot--active" : ""}`}
            style={{ backgroundColor: color }}
            title={tag}
            onClick={() => onChange(selected ? "" : tag)}
          >
            {selected && <Check size={9} color="#fff" strokeWidth={3} />}
          </button>
        );
      })}
      {value && !tags.includes(value) && (
        <span className="tag-custom-label">{value}</span>
      )}
    </div>
  );
}
