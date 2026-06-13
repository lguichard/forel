import { invoke } from "@tauri-apps/api/core";
import { open } from "@tauri-apps/plugin-dialog";
import { Check, Minus, Plus, X } from "lucide-react";
import { useEffect, useRef, useState } from "react";
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
const PRESENCE_OPERATORS: Operator[] = ["is", "is_not"];

const KIND_OPTIONS: { value: string; label: string }[] = [
  { value: "image",        label: "Image" },
  { value: "movie",        label: "Movie" },
  { value: "music",        label: "Music" },
  { value: "pdf",          label: "PDF" },
  { value: "text",         label: "Text" },
  { value: "document",     label: "Document" },
  { value: "presentation", label: "Presentation" },
  { value: "archive",      label: "Archive" },
  { value: "disk_image",   label: "Disk Image" },
  { value: "folder",       label: "Folder" },
  { value: "application",  label: "Application" },
];

// The 7 macOS system color labels, in Finder order.
const COLOR_LABELS = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"];

const SIZE_UNITS = ["bytes", "KB", "MB", "GB"] as const;

function operatorsFor(kind: ConditionKind): Operator[] {
  if (kind === "size_bytes") return NUMBER_OPERATORS;
  if (kind === "kind" || kind === "color_label") return PRESENCE_OPERATORS;
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
        onChange={(e) => {
          const kind = e.target.value as ConditionKind;
          let defaultValue = "";
          if (kind === "kind") defaultValue = KIND_OPTIONS[0].value;
          else if (kind === "color_label") defaultValue = COLOR_LABELS[0];
          onChange({ kind, operator: operatorsFor(kind)[0], value: defaultValue });
        }}
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

      {condition.kind === "kind" ? (
        <select
          className="condition-value"
          value={condition.value || KIND_OPTIONS[0].value}
          onChange={(e) => onChange({ value: e.target.value })}
        >
          {KIND_OPTIONS.map((opt) => (
            <option key={opt.value} value={opt.value}>
              {opt.label}
            </option>
          ))}
        </select>
      ) : condition.kind === "color_label" ? (
        <div className="tag-picker">
          {COLOR_LABELS.map((label) => {
            const selected = condition.value === label;
            return (
              <button
                key={label}
                type="button"
                className={`tag-dot${selected ? " tag-dot--active" : ""}`}
                style={{ backgroundColor: MACOS_TAG_COLORS[label] }}
                title={label}
                onClick={() => onChange({ value: label })}
              >
                {selected && <Check size={9} color="#fff" strokeWidth={3} />}
              </button>
            );
          })}
        </div>
      ) : condition.kind === "tags" ? (
        <TagPicker value={condition.value} onChange={(v) => onChange({ value: v })} />
      ) : condition.kind === "size_bytes" ? (
        <SizeValue value={condition.value} onChange={(v) => onChange({ value: v })} />
      ) : (
        <input
          className="condition-value"
          value={condition.value}
          placeholder="value"
          onChange={(e) => onChange({ value: e.target.value })}
        />
      )}

      <button className="row-remove" onClick={onRemove}>
        <Minus size={12} />
      </button>
    </div>
  );
}

// ---------- Size value (number + unit) ----------

function SizeValue({
  value,
  onChange,
}: {
  value: string;
  onChange: (v: string) => void;
}) {
  // Stored as "<number> <unit>" (e.g. "5 MB"); plain numbers are treated as bytes.
  const match = value.trim().match(/^([\d.]*)\s*(bytes|kb|mb|gb)?$/i);
  const num = match?.[1] ?? "";
  const rawUnit = match?.[2]?.toLowerCase();
  const unit = SIZE_UNITS.find((u) => u.toLowerCase() === rawUnit) ?? "bytes";

  const emit = (n: string, u: string) => onChange(n ? `${n} ${u}` : "");

  return (
    <div className="size-value">
      <input
        className="condition-value"
        type="number"
        min={0}
        value={num}
        placeholder="0"
        onChange={(e) => emit(e.target.value, unit)}
      />
      <select value={unit} onChange={(e) => emit(num, e.target.value)}>
        {SIZE_UNITS.map((u) => (
          <option key={u} value={u}>
            {u}
          </option>
        ))}
      </select>
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
  const needsColorLabel = action.kind === "set_color_label";
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
            value={(action.params.destination as string | undefined) ?? ""}
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
          value={(action.params.pattern as string | undefined) ?? ""}
          placeholder="{name} - {date_modified}"
          onChange={(e) =>
            onChange({ params: { ...action.params, pattern: e.target.value } })
          }
        />
      )}

      {needsTag && (
        <TagsListInput
          tags={Array.isArray(action.params.tags) ? (action.params.tags as string[]) : []}
          onChange={(tags) => onChange({ params: { ...action.params, tags } })}
        />
      )}

      {needsColorLabel && (
        <div className="tag-picker">
          {COLOR_LABELS.map((label) => {
            const selected = action.params.color === label;
            return (
              <button
                key={label}
                type="button"
                className={`tag-dot${selected ? " tag-dot--active" : ""}`}
                style={{ backgroundColor: MACOS_TAG_COLORS[label] }}
                title={label}
                onClick={() =>
                  onChange({
                    params: { ...action.params, color: selected ? "" : label },
                  })
                }
              >
                {selected && <Check size={9} color="#fff" strokeWidth={3} />}
              </button>
            );
          })}
        </div>
      )}

      {needsScript && (
        <textarea
          className="action-script"
          value={(action.params.script as string | undefined) ?? ""}
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

// ---------- Multi-tag chips input (used by add_tag / remove_tag actions) ----------

function TagsListInput({
  tags,
  onChange,
}: {
  tags: string[];
  onChange: (tags: string[]) => void;
}) {
  const [input, setInput] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);

  const commit = () => {
    const tag = input.trim();
    if (tag && !tags.includes(tag)) onChange([...tags, tag]);
    setInput("");
  };

  return (
    <div className="tags-list-input" onClick={() => inputRef.current?.focus()}>
      {tags.map((tag) => (
        <span key={tag} className="tags-list-chip">
          {tag}
          <button
            type="button"
            className="tags-list-chip-remove"
            onClick={(e) => {
              e.stopPropagation();
              onChange(tags.filter((t) => t !== tag));
            }}
          >
            <X size={9} />
          </button>
        </span>
      ))}
      <input
        ref={inputRef}
        className="tags-list-inline-input"
        value={input}
        placeholder={tags.length === 0 ? "Add tags…" : ""}
        onChange={(e) => setInput(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === "Tab") {
            e.preventDefault();
            commit();
          } else if (e.key === "Backspace" && !input && tags.length > 0) {
            onChange(tags.slice(0, -1));
          }
        }}
        onBlur={commit}
      />
    </div>
  );
}

// ---------- Color dot map (used by color-label pickers) ----------

const MACOS_TAG_COLORS: Record<string, string> = {
  Red: "#FF3B30",
  Orange: "#FF9500",
  Yellow: "#FFCC00",
  Green: "#34C759",
  Blue: "#007AFF",
  Purple: "#AF52DE",
  Gray: "#8E8E93",
};

// ---------- Text tag picker ----------
//
// Tags are free-form text labels, distinct from the colored Finder labels
// (handled separately by the color-label picker). The 7 system color names
// are filtered out here so they only appear as color labels, not as tags.

function TagPicker({
  value,
  onChange,
}: {
  value: string;
  onChange: (tag: string) => void;
}) {
  const [tags, setTags] = useState<string[]>([]);
  const [customInput, setCustomInput] = useState("");

  const loadTags = () => {
    invoke<string[]>("get_macos_tags")
      .then(setTags)
      .catch(() => {});
  };

  useEffect(loadTags, []);

  const applyCustom = async () => {
    const tag = customInput.trim();
    if (!tag) return;
    await invoke("add_custom_tag", { name: tag }).catch(() => {});
    onChange(tag);
    setCustomInput("");
    loadTags();
  };

  return (
    <div className="tag-picker-wrap">
      {tags.length > 0 && (
        <div className="tag-user-list">
          {tags.map((tag) => (
            <button
              key={tag}
              type="button"
              className={`tag-user-pill${value === tag ? " tag-user-pill--active" : ""}`}
              onClick={() => onChange(value === tag ? "" : tag)}
            >
              {tag}
            </button>
          ))}
        </div>
      )}

      <div className="tag-custom-input-row">
        <input
          className="tag-custom-input"
          value={customInput}
          placeholder="Add a tag…"
          onChange={(e) => setCustomInput(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && applyCustom()}
        />
        <button
          className="btn btn-secondary btn-sm"
          type="button"
          onClick={applyCustom}
          disabled={!customInput.trim()}
        >
          <Plus size={11} />
        </button>
      </div>

      {value && !tags.includes(value) && (
        <div className="tag-custom-selected">
          <span className="tag-custom-label">{value}</span>
          <button type="button" className="tag-custom-clear" onClick={() => onChange("")}>
            <X size={10} />
          </button>
        </div>
      )}
    </div>
  );
}
