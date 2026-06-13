use std::path::Path;

use anyhow::Result;

use super::{
    action, condition,
    model::{ConditionMatch, Rule},
};

/// Evaluates all enabled rules against `path` and executes matching ones.
/// Returns a list of rule names that matched.
pub fn evaluate_file(path: &Path, rules: &[Rule]) -> Vec<String> {
    let mut matched = Vec::new();

    for rule in rules.iter().filter(|r| r.enabled) {
        match rule_matches(rule, path) {
            Ok(true) => {
                execute_actions(rule, path);
                matched.push(rule.name.clone());
            }
            Ok(false) => {}
            Err(e) => {
                log::warn!("error evaluating rule '{}' on {:?}: {}", rule.name, path, e);
            }
        }
    }

    matched
}

fn rule_matches(rule: &Rule, path: &Path) -> Result<bool> {
    if rule.conditions.is_empty() {
        return Ok(false);
    }

    let results: Vec<bool> = rule
        .conditions
        .iter()
        .map(|c| condition::evaluate(c, path).unwrap_or(false))
        .collect();

    Ok(match rule.condition_match {
        ConditionMatch::All => results.iter().all(|&v| v),
        ConditionMatch::Any => results.iter().any(|&v| v),
    })
}

fn execute_actions(rule: &Rule, path: &Path) {
    let mut sorted = rule.actions.clone();
    sorted.sort_by_key(|a| a.position);

    for act in &sorted {
        if let Err(e) = action::execute(act, path) {
            log::error!(
                "action '{:?}' in rule '{}' failed on {:?}: {}",
                act.kind,
                rule.name,
                path,
                e
            );
        }
    }
}
