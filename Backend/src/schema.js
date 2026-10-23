// JSON-Schemata für strukturierte Ausgaben (output_config.format) und ein kleiner Validator
// für genau die verwendeten Schlüsselwörter. Die App validiert zusätzlich fachlich
// (u. a. ob Zitate wirklich im Material stehen).

const str = { type: "string" };
const strList = { type: "array", items: str };
const obj = (properties) => ({ type: "object", additionalProperties: false, required: Object.keys(properties), properties });

export const analyzeSchema = obj({
  topics: {
    type: "array",
    items: obj({
      title: str,
      summary: str,
      importance: { type: "string", enum: ["core", "standard", "peripheral"] },
      difficulty: { type: "integer", enum: [1, 2, 3] },
      prerequisites: strList,
      objectives: {
        type: "array",
        items: obj({
          title: str,
          description: str,
          bloom: { type: "string", enum: ["remember", "understand", "apply", "analyze"] },
          keyTerms: strList,
          chunkIds: strList,
          evidenceQuote: str,
        }),
      },
    }),
  },
  terms: {
    type: "array",
    items: obj({ term: str, definition: str, chunkId: str, quote: str, kind: { type: "string", enum: ["definition", "formula", "fact"] } }),
  },
  warnings: strList,
});

export const QUESTION_KINDS = ["multipleChoice", "trueFalse", "cloze", "shortAnswer", "freeText", "numeric", "matching"];

export const questionsSchema = obj({
  questions: {
    type: "array",
    items: obj({
      kind: { type: "string", enum: QUESTION_KINDS },
      prompt: str,
      options: strList,
      correctOptionIndices: { type: "array", items: { type: "integer" } },
      acceptedAnswers: strList,
      numeric: { anyOf: [obj({ value: { type: "number" }, unit: str, relativeTolerance: { type: "number" } }), { type: "null" }] },
      pairs: { type: "array", items: obj({ left: str, right: str }) },
      referenceAnswer: str,
      rubric: strList,
      explanation: str,
      simplerExplanation: str,
      commonMistakes: strList,
      difficulty: { type: "string", enum: ["easy", "medium", "hard"] },
      isTransfer: { type: "boolean" },
      chunkId: str,
      sourceQuote: str,
    }),
  },
  insufficientMaterial: { type: "boolean" },
});

export const gradeSchema = obj({
  score: { type: "number" },
  verdict: { type: "string", enum: ["correct", "partial", "incorrect"] },
  feedback: str,
  coveredPoints: strList,
  missingPoints: strList,
  confidence: { type: "string", enum: ["low", "medium", "high"] },
});

export const explainSchema = obj({
  explanation: str,
  chunkIds: strList,
  outsideMaterial: { type: "boolean" },
});

/// Prüft einen Wert gegen ein (Teilmengen-)JSON-Schema. Gibt eine Liste von Fehlern zurück.
export function validate(value, schema, path = "$") {
  if (schema.anyOf) {
    const results = schema.anyOf.map((s) => validate(value, s, path));
    return results.some((r) => r.length === 0) ? [] : [`${path}: passt zu keiner erlaubten Form`];
  }
  const errors = [];
  switch (schema.type) {
    case "null":
      if (value !== null) errors.push(`${path}: null erwartet`);
      return errors;
    case "string":
      if (typeof value !== "string") return [`${path}: Text erwartet`];
      break;
    case "number":
      if (typeof value !== "number" || !Number.isFinite(value)) return [`${path}: Zahl erwartet`];
      break;
    case "integer":
      if (!Number.isInteger(value)) return [`${path}: ganze Zahl erwartet`];
      break;
    case "boolean":
      if (typeof value !== "boolean") return [`${path}: Wahrheitswert erwartet`];
      break;
    case "array":
      if (!Array.isArray(value)) return [`${path}: Liste erwartet`];
      value.forEach((item, i) => errors.push(...validate(item, schema.items, `${path}[${i}]`)));
      return errors;
    case "object": {
      if (value === null || typeof value !== "object" || Array.isArray(value)) return [`${path}: Objekt erwartet`];
      for (const key of schema.required ?? []) {
        if (!(key in value)) errors.push(`${path}.${key}: fehlt`);
      }
      for (const [key, v] of Object.entries(value)) {
        const sub = schema.properties?.[key];
        if (!sub) {
          if (schema.additionalProperties === false) errors.push(`${path}.${key}: nicht erlaubt`);
          continue;
        }
        errors.push(...validate(v, sub, `${path}.${key}`));
      }
      return errors;
    }
    default:
      return [`${path}: unbekannter Schematyp`];
  }
  if (schema.enum && !schema.enum.includes(value)) errors.push(`${path}: unzulässiger Wert`);
  return errors;
}
