/** 
 * Copyright: Enalye
 * License: Zlib
 * Authors: Enalye
 */
module grimoire.stdlib.typecast;

import std.conv;
import grimoire.compiler, grimoire.runtime;

package(grimoire.stdlib) void grLoadStdLibTypecast(GrLibrary library) {
    //As int
    library.addCast(&typecast_r2i, grFloat, grInt, true);
    library.addCast(&typecast_b2i, grBool, grInt);

    //As float
    library.addCast(&typecast_i2r, grInt, grFloat);

    //As string
    library.addCast(&typecast_b2s, grBool, grString);
    library.addCast(&typecast_i2s, grInt, grString);
    library.addCast(&typecast_r2s, grFloat, grString);
    library.addCast(&typecast_as2s, grStringArray, grString);

    //As String Array
    library.addCast(&typecast_s2as, grString, grStringArray);
}

//As int
private void typecast_r2i(GrCall call) {
    call.setInt(to!int(call.getFloat(0)));
}

private void typecast_b2i(GrCall call) {
    call.setInt(to!int(call.getBool(0)));
}

//As float
private void typecast_i2r(GrCall call) {
    call.setFloat(to!float(call.getInt(0)));
}

//As string
private void typecast_b2s(GrCall call) {
    call.setString(call.getBool(0) ? "true" : "false");
}

private void typecast_i2s(GrCall call) {
    call.setString(to!string(call.getInt(0)));
}

private void typecast_r2s(GrCall call) {
    call.setString(to!string(call.getFloat(0)));
}

private void typecast_as2s(GrCall call) {
    string result;
    foreach (const sub; call.getStringArray(0).data) {
        result ~= sub;
    }
    call.setString(result);
}

//As string array
private void typecast_s2as(GrCall call) {
    GrStringArray result = new GrStringArray;
    foreach (const sub; call.getString(0)) {
        result.data ~= to!string(sub);
    }
    call.setStringArray(result);
}
