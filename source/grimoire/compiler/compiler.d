/**
    Grimoire compiler.

    Copyright: (c) Enalye 2018
    License: Zlib
    Authors: Enalye
*/

module grimoire.compiler.compiler;

import std.stdio, std.string, std.array, std.conv, std.math, std.file;
import grimoire.runtime, grimoire.assembly;
import grimoire.compiler.lexer, grimoire.compiler.parser, grimoire.compiler.primitive, grimoire.compiler.type;

/// Compile a source file into bytecode
GrBytecode grCompileFile(string fileName) {
	GrLexer lexer = new GrLexer;
	lexer.scanFile(to!dstring(fileName));

	GrParser parser = new GrParser;
	parser.parseScript(lexer);

	return generate(parser);
}

private {
	uint makeOpcode(uint instr, uint value) {
		return ((value << 8u) & 0xffffff00) | (instr & 0xff);
	}

	GrBytecode generate(GrParser parser) {
		uint nbOpcodes, lastOpcodeCount;

		foreach(func; parser.functions)
			nbOpcodes += cast(uint)func.instructions.length;

		foreach(func; parser.anonymousFunctions)
			nbOpcodes += cast(uint)func.instructions.length;

        foreach(func; parser.events)
			nbOpcodes += cast(uint)func.instructions.length;

        //We leave space for one kill instruction at the end.
        nbOpcodes ++;

		//Opcodes
		uint[] opcodes = new uint[nbOpcodes];

        //Start with the global initializations
        auto globalScope = "@global"d in parser.functions;
        if(globalScope) {
            foreach(uint i, instruction; globalScope.instructions)
                opcodes[lastOpcodeCount + i] = makeOpcode(cast(uint)instruction.opcode, instruction.value);
            lastOpcodeCount += cast(uint)globalScope.instructions.length;
            parser.functions.remove("@global"d);
        }

		//Then write the main function (not callable).
		auto mainFunc = "main"d in parser.functions;
		if(mainFunc is null)
			throw new Exception("No main declared.");

        mainFunc.position = lastOpcodeCount;
		foreach(uint i, instruction; mainFunc.instructions)
			opcodes[lastOpcodeCount + i] = makeOpcode(cast(uint)instruction.opcode, instruction.value);
        foreach(call; mainFunc.functionCalls)
			call.position += lastOpcodeCount;
		lastOpcodeCount += cast(uint)mainFunc.instructions.length;
		parser.functions.remove("main"d);

		//Every other functions.
        uint[dstring] events;
        foreach(dstring mangledName, GrFunction func; parser.events) {
			foreach(uint i, instruction; func.instructions)
				opcodes[lastOpcodeCount + i] = makeOpcode(cast(uint)instruction.opcode, instruction.value);
			foreach(call; func.functionCalls)
				call.position += lastOpcodeCount;
			func.position = lastOpcodeCount;
			lastOpcodeCount += func.instructions.length;
            events[mangledName] = func.position;
		}
		foreach(func; parser.anonymousFunctions) {
			foreach(uint i, instruction; func.instructions)
				opcodes[lastOpcodeCount + i] = makeOpcode(cast(uint)instruction.opcode, instruction.value);
			foreach(call; func.functionCalls)
				call.position += lastOpcodeCount;
			func.position = lastOpcodeCount;
			lastOpcodeCount += func.instructions.length;
		}
		foreach(func; parser.functions) {
			foreach(uint i, instruction; func.instructions)
				opcodes[lastOpcodeCount + i] = makeOpcode(cast(uint)instruction.opcode, instruction.value);
			foreach(call; func.functionCalls)
				call.position += lastOpcodeCount;
			func.position = lastOpcodeCount;
			lastOpcodeCount += func.instructions.length;
		}
		parser.solveFunctionCalls(opcodes);

        //The contexts will jump here if the VM is panicking.
        opcodes[$ - 1] = makeOpcode(cast(uint)GrOpcode.Unwind, 0);

		GrBytecode bytecode;
		bytecode.iconsts = parser.iconsts;
		bytecode.fconsts = parser.fconsts;
		bytecode.sconsts = parser.sconsts;
		bytecode.opcodes = opcodes;
		bytecode.events = events;
		return bytecode;
	}
}