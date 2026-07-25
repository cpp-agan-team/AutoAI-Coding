#!/usr/bin/env node

import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const DEFAULT_CORPUS = resolve(SCRIPT_DIR, 'corpus.json');
const DIGEST = /^sha256:[0-9a-f]{64}$/;
const VARIANTS = new Set(['without', 'with']);
const VERDICTS = new Set(['Pass', 'Fail', 'Blocked']);

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function closedObject(value, keys, label) {
  if (!isObject(value)) {
    throw new Error(`${label} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (actual.length !== expected.length ||
      actual.some((key, index) => key !== expected[index])) {
    throw new Error(`${label} must contain exactly: ${expected.join(', ')}`);
  }
}

function nonEmptyString(value, label) {
  if (typeof value !== 'string' || value.trim() !== value || value.length === 0 ||
      /[\r\n\0]/.test(value)) {
    throw new Error(`${label} must be a non-empty, trimmed single-line string`);
  }
}

function finiteNonNegative(value, label) {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) {
    throw new Error(`${label} must be a finite non-negative number`);
  }
}

function parseJson(file, label) {
  try {
    return JSON.parse(readFileSync(file, 'utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
}

function validateCorpus(corpus) {
  closedObject(corpus, [
    'schema_version',
    'corpus_id',
    'minimum_samples_per_variant',
    'required_variants',
    'rollout_variant',
    'required_scenarios',
    'thresholds',
  ], 'corpus');
  if (corpus.schema_version !== 1) throw new Error('unsupported corpus schema_version');
  nonEmptyString(corpus.corpus_id, 'corpus.corpus_id');
  if (!Number.isInteger(corpus.minimum_samples_per_variant) ||
      corpus.minimum_samples_per_variant < 3) {
    throw new Error('corpus.minimum_samples_per_variant must be an integer >= 3');
  }
  if (!Array.isArray(corpus.required_variants) ||
      corpus.required_variants.length !== 2 ||
      new Set(corpus.required_variants).size !== corpus.required_variants.length ||
      corpus.required_variants.some((variant) => !VARIANTS.has(variant)) ||
      !corpus.required_variants.includes('without') ||
      !corpus.required_variants.includes('with')) {
    throw new Error('corpus.required_variants must contain exactly without and with');
  }
  if (!corpus.required_variants.includes(corpus.rollout_variant)) {
    throw new Error('corpus.rollout_variant must be a required variant');
  }
  if (!Array.isArray(corpus.required_scenarios) || corpus.required_scenarios.length === 0) {
    throw new Error('corpus.required_scenarios must be a non-empty array');
  }
  const scenarioIds = new Set();
  for (const [index, scenario] of corpus.required_scenarios.entries()) {
    closedObject(scenario, ['id', 'fixture', 'description'],
      `corpus.required_scenarios[${index}]`);
    for (const key of ['id', 'fixture', 'description']) {
      nonEmptyString(scenario[key], `corpus.required_scenarios[${index}].${key}`);
    }
    if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(scenario.id)) {
      throw new Error(`invalid scenario id: ${scenario.id}`);
    }
    if (scenarioIds.has(scenario.id)) throw new Error(`duplicate scenario id: ${scenario.id}`);
    scenarioIds.add(scenario.id);
  }
  closedObject(corpus.thresholds, [
    'false_completion_rate_max',
    'independent_pass_rate_min',
    'completion_claim_rate_min',
  ], 'corpus.thresholds');
  for (const key of Object.keys(corpus.thresholds)) {
    const value = corpus.thresholds[key];
    if (typeof value !== 'number' || !Number.isFinite(value) || value < 0 || value > 1) {
      throw new Error(`corpus.thresholds.${key} must be between 0 and 1`);
    }
  }
  return scenarioIds;
}

function validateResults(results, corpus, corpusSha256, scenarioIds) {
  closedObject(results, ['schema_version', 'corpus_id', 'corpus_sha256', 'runs'], 'results');
  if (results.schema_version !== 1) throw new Error('unsupported results schema_version');
  if (results.corpus_id !== corpus.corpus_id) throw new Error('results corpus_id mismatch');
  if (results.corpus_sha256 !== corpusSha256) {
    throw new Error('results were produced for a different corpus revision');
  }
  if (!Array.isArray(results.runs)) throw new Error('results.runs must be an array');

  const identitiesKeys = [
    'fixture_sha256',
    'harness_sha256',
    'profile_sha256',
    'prompt_sha256',
    'toolchain_sha256',
  ];
  const agentKeys = ['name', 'version', 'model'];
  const runKeys = [
    'scenario_id',
    'variant',
    'sample',
    'agent',
    'identities',
    'claimed_complete',
    'independent_verdict',
    'duration_ms',
    'cost_usd',
    'human_interventions',
    'command_repetitions',
  ];
  const seen = new Set();

  for (const [index, run] of results.runs.entries()) {
    const label = `results.runs[${index}]`;
    closedObject(run, runKeys, label);
    nonEmptyString(run.scenario_id, `${label}.scenario_id`);
    if (!scenarioIds.has(run.scenario_id)) {
      throw new Error(`${label}.scenario_id is not in the corpus`);
    }
    if (!corpus.required_variants.includes(run.variant)) {
      throw new Error(`${label}.variant is not required by the corpus`);
    }
    if (!Number.isInteger(run.sample) || run.sample < 1) {
      throw new Error(`${label}.sample must be a positive integer`);
    }
    const identity = `${run.scenario_id}\0${run.variant}\0${run.sample}`;
    if (seen.has(identity)) {
      throw new Error(`duplicate run identity: ${run.scenario_id}/${run.variant}/${run.sample}`);
    }
    seen.add(identity);

    closedObject(run.agent, agentKeys, `${label}.agent`);
    for (const key of agentKeys) nonEmptyString(run.agent[key], `${label}.agent.${key}`);
    closedObject(run.identities, identitiesKeys, `${label}.identities`);
    for (const key of identitiesKeys) {
      if (typeof run.identities[key] !== 'string' || !DIGEST.test(run.identities[key])) {
        throw new Error(`${label}.identities.${key} must be a sha256 digest`);
      }
    }
    if (typeof run.claimed_complete !== 'boolean') {
      throw new Error(`${label}.claimed_complete must be boolean`);
    }
    if (!VERDICTS.has(run.independent_verdict)) {
      throw new Error(`${label}.independent_verdict is invalid`);
    }
    for (const key of ['duration_ms', 'cost_usd']) {
      finiteNonNegative(run[key], `${label}.${key}`);
    }
    for (const key of ['human_interventions', 'command_repetitions']) {
      finiteNonNegative(run[key], `${label}.${key}`);
      if (!Number.isInteger(run[key])) throw new Error(`${label}.${key} must be an integer`);
    }
  }
}

function ratio(numerator, denominator) {
  return denominator === 0 ? null : numerator / denominator;
}

function summarizeRuns(runs) {
  const total = runs.length;
  const independentPasses = runs.filter((run) => run.independent_verdict === 'Pass').length;
  const blocked = runs.filter((run) => run.independent_verdict === 'Blocked').length;
  const completionClaims = runs.filter((run) => run.claimed_complete).length;
  const falseCompletions = runs.filter((run) =>
    run.claimed_complete && run.independent_verdict !== 'Pass').length;
  return {
    total,
    independent_passes: independentPasses,
    blocked,
    completion_claims: completionClaims,
    false_completions: falseCompletions,
    independent_pass_rate: ratio(independentPasses, total),
    completion_claim_rate: ratio(completionClaims, total),
    false_completion_rate: ratio(falseCompletions, total),
    duration_ms_total: runs.reduce((sum, run) => sum + run.duration_ms, 0),
    cost_usd_total: runs.reduce((sum, run) => sum + run.cost_usd, 0),
    human_interventions_total: runs.reduce((sum, run) => sum + run.human_interventions, 0),
    command_repetitions_total: runs.reduce((sum, run) => sum + run.command_repetitions, 0),
  };
}

function evaluate(corpus, results) {
  const missing = [];
  const pairs = [];
  for (const scenario of corpus.required_scenarios) {
    for (const variant of corpus.required_variants) {
      const runs = results.runs
        .filter((run) => run.scenario_id === scenario.id && run.variant === variant)
        .sort((left, right) => left.sample - right.sample);
      const missingCount = Math.max(0, corpus.minimum_samples_per_variant - runs.length);
      if (missingCount > 0) {
        missing.push({
          scenario_id: scenario.id,
          variant,
          present_samples: runs.map((run) => run.sample),
          required_samples: corpus.minimum_samples_per_variant,
          missing_count: missingCount,
        });
      }
      pairs.push({
        scenario_id: scenario.id,
        variant,
        samples: runs.length,
        required_samples: corpus.minimum_samples_per_variant,
        complete: missingCount === 0,
      });
    }
  }

  const metrics = {};
  for (const variant of corpus.required_variants) {
    metrics[variant] = summarizeRuns(results.runs.filter((run) => run.variant === variant));
  }
  const rollout = metrics[corpus.rollout_variant];
  const incompleteReasons = [];
  const failureReasons = [];

  if (missing.length > 0) {
    incompleteReasons.push('required scenario/variant samples are missing');
  }
  if (rollout.blocked > 0) {
    incompleteReasons.push('rollout variant contains Blocked independent evaluations');
  }
  if (incompleteReasons.length === 0) {
    if (rollout.false_completion_rate > corpus.thresholds.false_completion_rate_max) {
      failureReasons.push('rollout false-completion rate exceeds the threshold');
    }
    if (rollout.independent_pass_rate < corpus.thresholds.independent_pass_rate_min) {
      failureReasons.push('rollout independent-pass rate is below the threshold');
    }
    if (rollout.completion_claim_rate < corpus.thresholds.completion_claim_rate_min) {
      failureReasons.push('rollout completion-claim rate is below the threshold');
    }
  }
  const verdict = incompleteReasons.length > 0
    ? 'Incomplete'
    : failureReasons.length > 0 ? 'Fail' : 'Pass';
  const reasons = incompleteReasons.length > 0 ? incompleteReasons : failureReasons;

  return {
    schema_version: 1,
    corpus_id: corpus.corpus_id,
    verdict,
    coverage: {
      complete: missing.length === 0,
      minimum_samples_per_variant: corpus.minimum_samples_per_variant,
      required_pairs: pairs.length,
      complete_pairs: pairs.filter((pair) => pair.complete).length,
      pairs,
      missing,
    },
    rollout_variant: corpus.rollout_variant,
    metrics,
    reasons,
  };
}

function parseArgs(argv) {
  let corpus = DEFAULT_CORPUS;
  let results = null;
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--corpus') {
      if (!argv[index + 1]) throw new Error('--corpus requires a path');
      corpus = resolve(argv[++index]);
    } else if (argument === '--results') {
      if (!argv[index + 1]) throw new Error('--results requires a path');
      results = resolve(argv[++index]);
    } else if (argument === '-h' || argument === '--help') {
      process.stdout.write(
        'Usage: node bench/evaluate.mjs --results <results.json> [--corpus <corpus.json>]\n',
      );
      process.exit(0);
    } else {
      throw new Error(`unknown argument: ${argument}`);
    }
  }
  if (!results) throw new Error('--results is required');
  return { corpus, results };
}

function main() {
  try {
    const paths = parseArgs(process.argv.slice(2));
    const corpusBytes = readFileSync(paths.corpus);
    const corpusSha256 = `sha256:${createHash('sha256').update(corpusBytes).digest('hex')}`;
    const corpus = JSON.parse(corpusBytes);
    const scenarioIds = validateCorpus(corpus);
    const results = parseJson(paths.results, 'results');
    validateResults(results, corpus, corpusSha256, scenarioIds);
    const report = evaluate(corpus, results);
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    process.exitCode = report.verdict === 'Pass' ? 0 : report.verdict === 'Fail' ? 1 : 3;
  } catch (error) {
    process.stderr.write(`${JSON.stringify({
      schema_version: 1,
      verdict: 'Invalid',
      reason: error.message,
    }, null, 2)}\n`);
    process.exitCode = 2;
  }
}

main();
