import { create } from "zustand";
import { PreviewResult, Rule, WatchedFolder } from "../types";
import {
  AddWatchedFolder,
  CreateRule,
  DeleteRule,
  GetRules,
  GetWatchedFolders,
  PreviewRules,
  RemoveWatchedFolder,
  RunRulesNow,
  ToggleRule,
  ToggleWatchedFolder,
  UpdateRule,
} from "../../bindings/forel/app";
import type { Rule as GenRule } from "../../bindings/forel/internal/rules/models";

// The generated Wails bindings model the same JSON shapes as ../types but with
// enum types instead of string unions. Runtime values are identical, so we cast
// at this boundary and keep ../types as the source of truth for the UI.
interface ForelState {
  folders: WatchedFolder[];
  selectedFolderId: string | null;
  rules: Rule[];
  loading: boolean;

  // Folder actions
  fetchFolders: () => Promise<void>;
  addFolder: (path: string) => Promise<void>;
  removeFolder: (id: string) => Promise<void>;
  toggleFolder: (id: string, enabled: boolean) => Promise<void>;
  selectFolder: (id: string | null) => void;

  // Rule actions
  fetchRules: (folderId: string) => Promise<void>;
  createRule: (folderId: string, name: string) => Promise<Rule>;
  updateRule: (rule: Rule) => Promise<void>;
  deleteRule: (ruleId: string) => Promise<void>;
  toggleRule: (ruleId: string, enabled: boolean) => Promise<void>;
  runRulesNow: (folderId: string) => Promise<string[]>;
  previewRules: (folderId: string) => Promise<PreviewResult>;
}

export const useForelStore = create<ForelState>((set, get) => ({
  folders: [],
  selectedFolderId: null,
  rules: [],
  loading: false,

  fetchFolders: async () => {
    const folders = (await GetWatchedFolders()) as unknown as WatchedFolder[];
    set({ folders });
  },

  addFolder: async (path) => {
    const folder = (await AddWatchedFolder(path)) as unknown as WatchedFolder;
    set((s) => ({ folders: [...s.folders, folder] }));
  },

  removeFolder: async (id) => {
    await RemoveWatchedFolder(id);
    set((s) => ({
      folders: s.folders.filter((f) => f.id !== id),
      selectedFolderId: s.selectedFolderId === id ? null : s.selectedFolderId,
      rules: s.selectedFolderId === id ? [] : s.rules,
    }));
  },

  toggleFolder: async (id, enabled) => {
    await ToggleWatchedFolder(id, enabled);
    set((s) => ({
      folders: s.folders.map((f) => (f.id === id ? { ...f, enabled } : f)),
    }));
  },

  selectFolder: (id) => {
    set({ selectedFolderId: id, rules: [] });
    if (id) void get().fetchRules(id);
  },

  fetchRules: async (folderId) => {
    set({ loading: true });
    try {
      const rules = (await GetRules(folderId)) as unknown as Rule[];
      set({ rules });
    } finally {
      set({ loading: false });
    }
  },

  createRule: async (folderId, name) => {
    const rule = (await CreateRule(folderId, name)) as unknown as Rule;
    set((s) => ({ rules: [...s.rules, rule] }));
    return rule;
  },

  updateRule: async (rule) => {
    await UpdateRule(rule as unknown as GenRule);
    set((s) => ({
      rules: s.rules.map((r) => (r.id === rule.id ? rule : r)),
    }));
  },

  deleteRule: async (ruleId) => {
    await DeleteRule(ruleId);
    set((s) => ({ rules: s.rules.filter((r) => r.id !== ruleId) }));
  },

  toggleRule: async (ruleId, enabled) => {
    await ToggleRule(ruleId, enabled);
    set((s) => ({
      rules: s.rules.map((r) => (r.id === ruleId ? { ...r, enabled } : r)),
    }));
  },

  runRulesNow: async (folderId) => {
    return RunRulesNow(folderId);
  },

  previewRules: async (folderId) => {
    return (await PreviewRules(folderId)) as unknown as PreviewResult;
  },
}));
