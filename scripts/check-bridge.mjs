// Compiles the JavaScript in App/Web/BridgeScript.swift without running it, so a syntax error there
// fails the build instead of the app. WebKit runs that script before the page's own, and one error in
// it stops all of it: no bridge, so no storage put back, no TV layout and no remote (d22e6c8).
//
//   node scripts/check-bridge.mjs
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

// Another copy can be named, to try the check on an old revision.
const file =
  process.argv[2] ?? fileURLToPath(new URL('../App/Web/BridgeScript.swift', import.meta.url));
// A checkout on Windows can have CRLF line ends.
const swift = readFileSync(file, 'utf8').replace(/^\uFEFF/, '').replace(/\r\n/g, '\n');

// The template is a Swift raw string, so its text is the script as WebKit gets it.
const open = 'private static let template = #"""\n';
const start = swift.indexOf(open);
const end = swift.indexOf('\n"""#', start + open.length);
if (start < 0 || end < 0) {
  console.error(`check-bridge: no template = #""" ... """# in ${file}`);
  process.exit(1);
}
const template = swift.slice(start + open.length, end);
const firstLine = swift.slice(0, start + open.length).split('\n').length;

// What BridgeScript.make puts in its place: string literals, and the storage as a JSON object.
const script = template
  .replaceAll('__VERSION__', '"0"')
  .replaceAll('__DEVICE_ID__', '"device"')
  .replaceAll('__DEVICE__', '"Apple TV"')
  .replaceAll('__STORAGE__', '{}');
const left = script.match(/__[A-Z_]+__/);
if (left) {
  console.error(`check-bridge: ${left[0]} is in the template but BridgeScript.make doesn't fill it, nor this check`);
  process.exit(1);
}

try {
  // Compiled as a script, as WebKit's user script is: a name declared twice is caught here.
  new vm.Script(script, { filename: 'BridgeScript.swift', lineOffset: firstLine - 1 });
} catch (error) {
  const where = error.stack?.split('\n')[0] ?? '';
  console.error(`check-bridge: the bridge script doesn't compile: ${error.message}\n  ${where}`);
  process.exit(1);
}
console.log(`check-bridge: the bridge script compiles (${template.split('\n').length} lines)`);
