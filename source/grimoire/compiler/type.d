/** 
 * Copyright: Enalye
 * License: Zlib
 * Authors: Enalye
 */
module grimoire.compiler.type;

import std.conv: to;

import grimoire.runtime;
import grimoire.assembly;
import grimoire.compiler.mangle;
import grimoire.compiler.data;

/**
Type category.

Complex types use mangledType and mangledReturnType
to represent them.
*/
enum GrBaseType {
    void_, int_, float_, bool_, string_,
    array_, function_, task,
    class_, foreign, chan, enum_,
    internalTuple,
    reference, 
}

/**
Compiler type definition for Grimoire's type system.
It doesn't mean anything for the VM.
*/
struct GrType {
    /// General type, basic types only use that while compound types also use mangledType
    /// and mangledReturnType.
    GrBaseType baseType;
    /// Used for compound types like arrays, functions, etc.
    dstring mangledType, mangledReturnType;
    /// Is this from an object field ?
    bool isField;

    /// Init as a basic type.
    this(GrBaseType baseType_) {
        baseType = baseType_;
    }

    /// Compound type.
    this(GrBaseType baseType_, dstring mangledType_) {
        baseType = baseType_;
        mangledType = mangledType_;
    }

    /// Only assign a simple type (baseType).
    GrType opOpAssign(string op)(GrBaseType t) {
		mixin("baseType = baseType" ~ op ~ "t;");
		return this;
	}

    /// Check general type equality.
    bool opEquals(const GrBaseType v) const {
		return (baseType == v);
	}
    
    /// Check full type equality.
    bool opEquals(const GrType v) const {
        if(baseType != v.baseType)
            return false;
        if(baseType == GrBaseType.function_ || baseType == GrBaseType.task)
            return mangledType == v.mangledType && mangledReturnType == v.mangledReturnType;
        return true;
	}

    /// Only to disable warnings because of opEquals.
	size_t toHash() const @safe pure nothrow {
		return 0;
	}
}

/// No type
const GrType grVoid = GrType(GrBaseType.void_);
/// Integer
const GrType grInt = GrType(GrBaseType.int_);
/// Float
const GrType grFloat = GrType(GrBaseType.float_);
/// Bool
const GrType grBool = GrType(GrBaseType.bool_);
/// String
const GrType grString = GrType(GrBaseType.string_);
/// Int array
const GrType grIntArray = GrType(GrBaseType.array_, grMangleFunction([grInt]));
/// Float array
const GrType grFloatArray = GrType(GrBaseType.array_, grMangleFunction([grFloat]));
/// String array
const GrType grStringArray = GrType(GrBaseType.array_, grMangleFunction([grString]));

/// Pack multiple types as a single one.
package GrType grPackTuple(GrType[] types) {
    const dstring mangledName = grMangleFunction(types);
    GrType type = GrBaseType.internalTuple;
    type.mangledType = mangledName;
    return type;
}

/// Unpack multiple types from a single one.
package GrType[] grUnpackTuple(GrType type) {
    if(type.baseType != GrBaseType.internalTuple)
        throw new Exception("Cannot unpack a not tuple type.");
    return grUnmangleSignature(type.mangledType);
}

/**
A local or global variable.
*/
package class GrVariable {
    /// Its type.
	GrType type;
    /// Register position, separate for each type (int, float, string and objects);
    uint register = uint.max;
    /// Declared from the global scope ?
	bool isGlobal;
    /// Declared from an object definition ?
    bool isField;
    /// Does it have a value yet ?
    bool isInitialized;
    /// Is the type to be infered automatically ? (e.g. the `let` keyword).
    bool isAuto;
    /// Can we modify its value ?
    bool isConstant;
    /// Its unique name inside its scope (function based scope).
    dstring name;
    /// Is the variable visible from other files ? (Global only)
    bool isPublic;
    /// The file where the variable is declared.
    uint fileId;
}

/// Create a foreign GrType for the type system.
GrType grGetForeignType(dstring name) {
    GrType type = GrBaseType.foreign;
    type.mangledType = name;
    return type;
}

/**
Define the content of a type alias. \
Not to be confused with GrType used by the type system.
---
type MyNewType = AnotherType;
---
*/
final class GrTypeAliasDefinition {
    /// Identifier.
    dstring name;
    /// The type aliased.
    GrType type;
}

/**
Define the content of an enum. \
Not to be confused with GrType used by the type system.
---
enum MyEnum {
    field1;
    field2;
}
---
*/
final class GrEnumDefinition {
    /// Identifier.
    dstring name;
    /// List of field names.
    dstring[] fields;
    /// Unique ID of the enum definition.
    size_t index;

    /// Does the field name exists ?
    bool hasField(dstring name) const {
        foreach(field; fields) {
            if(field == name)
                return true;
        }
        return false;
    }

    /// Returns the value of the field
    int getField(dstring name) const {
        import std.conv: to;
        int fieldIndex = 0;
        foreach(field; fields) {
            if(field == name)
                return fieldIndex;
            fieldIndex ++;
        }
        assert(false, "Undefined enum \'" ~ to!string(name) ~ "\'");
    }
}

/// Create a GrType of enum for the type system.
GrType grGetEnumType(dstring name) {
    GrType stType = GrBaseType.enum_;
    stType.mangledType = name;
    return stType;
}

/**
Define the content of a class. \
Not to be confused with GrType used by the type system.
---
class MyClass {
    // Fields
}
---
*/
final class GrClassDefinition {
    /// Identifier.
    dstring name;
    /// List of field types.
    GrType[] signature;
    /// List of field names.
    dstring[] fields;
    /// Unique ID of the object definition.
    size_t index;
}

/// Create a GrType of class for the type system.
GrType grGetClassType(dstring name) {
    GrType stType = GrBaseType.class_;
    stType.mangledType = name;
    return stType;
}

/// A single instruction used by the VM.
struct GrInstruction {
    /// What needs to be done.
	GrOpcode opcode;
    /// Payload, may not be used.
	uint value;
}

/**
Function/Task/Event definition.
*/
package class GrFunction {
    /// Every variable declared within its scope.
	GrVariable[dstring] localVariables;
    /// All the function instructions.
	GrInstruction[] instructions;
	uint stackSize, index, offset;

    /// Unmangled function name.
	dstring name;
    /// Function parameters' type.
	GrType[] inSignature, outSignature;
	bool isTask, isAnonymous;

    /// Function calls made from within its scope.
	GrFunctionCall[] functionCalls;
	GrFunction anonParent;
	uint position, anonReference;

	uint nbIntegerParameters, nbFloatParameters, nbStringParameters, nbObjectParameters;
    uint ilocalsCount, flocalsCount, slocalsCount, olocalsCount;

    GrDeferrableSection[] deferrableSections;
    GrDeferBlock[] registeredDeferBlocks;
    bool[] isDeferrableSectionLocked = [false];

    /// Is the function visible from other files ?
    bool isPublic;
    /// The file where the function is declared.
    uint fileId;
}

package class GrFunctionCall {
	dstring mangledName;
	uint position;
	GrFunction caller, functionToCall;
	GrType expectedType;
    bool isAddress;
    uint fileId;
}

package class GrDeferrableSection {
    GrDeferBlock[] deferredBlocks;
    uint deferInitPositions;
    uint[] deferredCalls;
}

package class GrDeferBlock {
    uint position;
    uint parsePosition;
    uint scopeLevel;
}