// Copyright (c) 2020- Bluespec, Inc. All Rights Reserved.
// This package captures definitions used by the ATCM logic

package ATCM_Decls;
import Vector        :: *;
import ISA_Decls     :: *;

// ATCM related type definitions
//
// --- USER CONFIGURABLE
typedef 32 ATCM_XLEN;          // ATCM Width

// ATCM Sizing
`ifdef ATCM_16K
typedef 16 KB_PER_ATCM;
`elsif ATCM_32K
typedef 32 KB_PER_ATCM;
`elsif ATCM_64K
typedef 64 KB_PER_ATCM;
`endif

// --- USER CONFIGURABLE
//

typedef Bit #(ATCM_XLEN)                   ATCM_Word;
typedef TDiv #(ATCM_XLEN, Bits_per_Byte)   Bytes_per_ATCM_Word;
typedef TLog #(Bytes_per_ATCM_Word)        Bits_per_Byte_in_ATCM_Word;
typedef Bit #(Bits_per_Byte_in_ATCM_Word)  Byte_in_ATCM_Word;
typedef Vector #(Bytes_per_ATCM_Word, Byte) ATCM_Word_B;
Integer bytes_per_atcm_word        = valueOf (Bytes_per_ATCM_Word);
Integer bits_per_byte_in_atcm_word = valueOf (Bits_per_Byte_in_ATCM_Word);
Integer addr_lo_byte_in_atcm_word = 0;
Integer addr_hi_byte_in_atcm_word = addr_lo_byte_in_atcm_word + bits_per_byte_in_atcm_word - 1;

function  Byte_in_ATCM_Word fn_addr_to_byte_in_atcm_word (Addr a);
   return a [addr_hi_byte_in_atcm_word : addr_lo_byte_in_atcm_word ];
endfunction

Integer kb_per_atcm =   valueOf (KB_PER_ATCM);   // ATCM Sizing
Integer bytes_per_ATCM = kb_per_atcm * 'h400;

// LSBs to address a byte in the ATCMs
typedef TAdd# (TLog# (KB_PER_ATCM), TLog #(1024)) ATCM_Addr_LSB;
Integer atcm_addr_lsb = valueOf (ATCM_Addr_LSB);

// Indices into the ATCM
typedef Bit #(TAdd #(TLog #(KB_PER_ATCM), 8)) ATCM_INDEX;//(KB*1024)/ bytes_per_atcm_word

// size of the BRAM in ATCM_Word(s). Only handles powers of two.
Integer n_words_BRAM = (bytes_per_ATCM / bytes_per_atcm_word);

endpackage

