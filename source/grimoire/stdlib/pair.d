/** 
 * Copyright: Enalye
 * License: Zlib
 * Authors: Enalye
 */
module grimoire.stdlib.pair;

import grimoire.compiler, grimoire.runtime;

package(grimoire.stdlib) void grLoadStdLibPair(GrLibrary library) {
    library.addClass("Pair", ["first", "second"], [grAny("A"), grAny("B")], ["A", "B"]);
}