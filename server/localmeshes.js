// Local meshes: server-side storage for EditableMesh content, which Studio
// doesn't save with the place. The plugin tags each MeshPart whose mesh is
// stored here with a mesh id (a UUID), uploads the mesh whenever a tool
// changes it, and downloads it again when the place is opened (see
// studio_plugin_src/System/LocalMeshes.luau).
//
// Layout: <LOCAL_MESH_DIR>/place-<placeId>/<id>.lmesh (the encoded mesh, as
// sent by the plugin; see System/MeshCodec.luau) plus <id>.json (metadata:
// part and place names, counts, time). Unpublished places have place id 0.
// A mesh is looked up in its place's folder first, then in every other one,
// so meshes survive publishing a place (its id changes) or copying it.

const fs = require("node:fs");
const path = require("node:path");
const { REPO_ROOT } = require("./tree");

const LOCAL_MESH_DIR = path.resolve(process.env.LOCAL_MESH_DIR || path.join(REPO_ROOT, "local_meshes"));
const MAX_BODY_BYTES = 64 * 1024 * 1024;

const ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function placeDir(placeId) {
  return path.join(LOCAL_MESH_DIR, `place-${placeId}`);
}

function validate(placeId, id) {
  if (!/^\d{1,20}$/.test(String(placeId))) return "invalid place id";
  if (typeof id !== "string" || !ID_PATTERN.test(id)) return "invalid mesh id";
  return null;
}

// Writes atomically (temp file + rename) so a crash never leaves half a mesh.
function writeAtomic(file, data) {
  const temp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temp, data);
  fs.renameSync(temp, file);
}

// body: { placeId, id, data (base64), meta }
function save(body) {
  const error = validate(body.placeId, body.id);
  if (error) return { status: 400, body: { error } };
  if (typeof body.data !== "string" || body.data.length === 0) return { status: 400, body: { error: "missing data" } };
  const data = Buffer.from(body.data, "base64");
  const dir = placeDir(body.placeId);
  fs.mkdirSync(dir, { recursive: true });
  const meta = { ...(typeof body.meta === "object" && body.meta ? body.meta : {}), id: body.id, placeId: Number(body.placeId), bytes: data.length, updated: new Date().toISOString() };
  writeAtomic(path.join(dir, `${body.id}.lmesh`), data);
  writeAtomic(path.join(dir, `${body.id}.json`), JSON.stringify(meta, null, 2));
  return { status: 200, body: { ok: true, bytes: data.length } };
}

// The file for a mesh id: in the place's own folder, else the most recently
// written copy in any other place's folder.
function find(placeId, id) {
  const own = path.join(placeDir(placeId), `${id}.lmesh`);
  if (fs.existsSync(own)) return own;
  let best = null;
  let bestTime = -1;
  let entries = [];
  try {
    entries = fs.readdirSync(LOCAL_MESH_DIR, { withFileTypes: true });
  } catch {
    return null;
  }
  for (const entry of entries) {
    if (!entry.isDirectory() || !entry.name.startsWith("place-")) continue;
    const file = path.join(LOCAL_MESH_DIR, entry.name, `${id}.lmesh`);
    try {
      const time = fs.statSync(file).mtimeMs;
      if (time > bestTime) {
        best = file;
        bestTime = time;
      }
    } catch {
      // not in this place
    }
  }
  return best;
}

// -> { id, data (base64) } or 404
function load(placeId, id) {
  const error = validate(placeId, id);
  if (error) return { status: 400, body: { error } };
  const file = find(placeId, id);
  if (!file) return { status: 404, body: { error: `no stored mesh ${id}` } };
  return { status: 200, body: { id, data: fs.readFileSync(file).toString("base64") } };
}

module.exports = { LOCAL_MESH_DIR, MAX_BODY_BYTES, save, load };
