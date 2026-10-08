#!/usr/bin/env node
// Downloads the libraries pinned in libraries.json into .libraries/ (the
// release .rbxmx plus its modules extracted as .luau files). `npm run check`
// and `npm run install-plugin` do this automatically when needed.
//
//   npm run sync-libraries

const libraries = require("../server/libraries");

libraries
  .syncLibraries()
  .then((libs) => {
    for (const lib of libs) console.log(`${lib.name} ${lib.tag}: ${lib.sourceDir}`);
    if (libs.length === 0) console.log("No libraries in libraries.json.");
  })
  .catch((err) => {
    console.error(err.message);
    process.exitCode = 1;
  });
