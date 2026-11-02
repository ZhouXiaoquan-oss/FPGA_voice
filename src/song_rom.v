// ============================================================================
// song_rom.v -- SubTask-014-A preset score ROM (3 songs, 96 notes)
// ============================================================================
// Contract (L2 final work order 20261017_195038, section 5):
//   1024 x 18 single-port BSRAM, one physical block.  Words 0..15 are the
//   three 32-bit song indexes (2 words each); words 16+3j..18+3j hold note j
//   as low/mid/high 16-bit slices.  Each physical word has 2 pad bits [17:16]
//   tied to zero.  Logical note payload:
//     [3:0] key, [24:4] absolute start frame (21 bits), [40:25] duration,
//     [47:41] reserved = 0.
//   Index payload (32 bits): [8:0] start note address, [17:9] note count,
//   [31:18] zero.
// Read: one clk latency; rd_valid is the delayed rd_en; back-to-back reads
// return one word per clock.
//
// Content is generated from the L1-approved 曲目备案表 by
// .workbuddy/p6t14a_gen_rom.py; the independent reference vectors
// SubTask-014-A_索引参考_20261017_202558.mem and
// SubTask-014-A_音符参考_20261017_202558.mem are produced by the same parser
// (Markdown in, vectors out) and are what the TB compares against.
// ============================================================================
`default_nettype none

module song_rom (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        guide_rom_rd_en,
    input  wire [9:0]  guide_rom_rd_addr,
    output wire [17:0] guide_rom_rd_data,
    output wire        guide_rom_rd_valid
);

    // 1024 x 18 single-port BSRAM.  Initial contents are part of the design
    // (Gowin BSRAM supports initialised memory); unused words are zero.
    reg [17:0] mem [0:1023];

    integer i;
    initial begin
        for (i = 0; i < 1024; i = i + 1)
            mem[i] = 18'd0;
        mem[0] = 18'h05400;
        mem[2] = 18'h03C2A;
        mem[4] = 18'h03048;
        mem[17] = 18'h0BC00;
        mem[18] = 18'h000BE;
        mem[19] = 18'h0F5E0;
        mem[20] = 18'h0BC05;
        mem[21] = 18'h000BE;
        mem[22] = 18'h0EBC4;
        mem[23] = 18'h0BC0B;
        mem[24] = 18'h000BE;
        mem[25] = 18'h0E1A4;
        mem[26] = 18'h0BC11;
        mem[27] = 18'h000BE;
        mem[28] = 18'h0D785;
        mem[29] = 18'h0BC17;
        mem[30] = 18'h000BE;
        mem[31] = 18'h0CD65;
        mem[32] = 18'h0BC1D;
        mem[33] = 18'h000BE;
        mem[34] = 18'h0C344;
        mem[35] = 18'h07A23;
        mem[36] = 18'h0017D;
        mem[37] = 18'h0AF13;
        mem[38] = 18'h0BC2F;
        mem[39] = 18'h000BE;
        mem[40] = 18'h0A4F3;
        mem[41] = 18'h0BC35;
        mem[42] = 18'h000BE;
        mem[43] = 18'h09AD2;
        mem[44] = 18'h0BC3B;
        mem[45] = 18'h000BE;
        mem[46] = 18'h090B2;
        mem[47] = 18'h0BC41;
        mem[48] = 18'h000BE;
        mem[49] = 18'h08691;
        mem[50] = 18'h0BC47;
        mem[51] = 18'h000BE;
        mem[52] = 18'h07C71;
        mem[53] = 18'h0BC4D;
        mem[54] = 18'h000BE;
        mem[55] = 18'h07250;
        mem[56] = 18'h07853;
        mem[57] = 18'h0017D;
        mem[58] = 18'h05E14;
        mem[59] = 18'h0BC5F;
        mem[60] = 18'h000BE;
        mem[61] = 18'h053F4;
        mem[62] = 18'h0BC65;
        mem[63] = 18'h000BE;
        mem[64] = 18'h049D3;
        mem[65] = 18'h0BC6B;
        mem[66] = 18'h000BE;
        mem[67] = 18'h03FB3;
        mem[68] = 18'h0BC71;
        mem[69] = 18'h000BE;
        mem[70] = 18'h03592;
        mem[71] = 18'h0BC77;
        mem[72] = 18'h000BE;
        mem[73] = 18'h02B72;
        mem[74] = 18'h0BC7D;
        mem[75] = 18'h000BE;
        mem[76] = 18'h02151;
        mem[77] = 18'h07A83;
        mem[78] = 18'h0017D;
        mem[79] = 18'h00D24;
        mem[80] = 18'h0BC8F;
        mem[81] = 18'h000BE;
        mem[82] = 18'h00304;
        mem[83] = 18'h0BC95;
        mem[84] = 18'h000BE;
        mem[85] = 18'h0F8E3;
        mem[86] = 18'h0BC9A;
        mem[87] = 18'h000BE;
        mem[88] = 18'h0EEC3;
        mem[89] = 18'h0BCA0;
        mem[90] = 18'h000BE;
        mem[91] = 18'h0E4A2;
        mem[92] = 18'h0BCA6;
        mem[93] = 18'h000BE;
        mem[94] = 18'h0DA82;
        mem[95] = 18'h0BCAC;
        mem[96] = 18'h000BE;
        mem[97] = 18'h0D061;
        mem[98] = 18'h078B2;
        mem[99] = 18'h0017D;
        mem[100] = 18'h0BC20;
        mem[101] = 18'h0BCBE;
        mem[102] = 18'h000BE;
        mem[103] = 18'h0B200;
        mem[104] = 18'h0BCC4;
        mem[105] = 18'h000BE;
        mem[106] = 18'h0A7E4;
        mem[107] = 18'h0BCCA;
        mem[108] = 18'h000BE;
        mem[109] = 18'h09DC4;
        mem[110] = 18'h0BCD0;
        mem[111] = 18'h000BE;
        mem[112] = 18'h093A5;
        mem[113] = 18'h0BCD6;
        mem[114] = 18'h000BE;
        mem[115] = 18'h08985;
        mem[116] = 18'h0BCDC;
        mem[117] = 18'h000BE;
        mem[118] = 18'h07F64;
        mem[119] = 18'h07AE2;
        mem[120] = 18'h0017D;
        mem[121] = 18'h06B33;
        mem[122] = 18'h0BCEE;
        mem[123] = 18'h000BE;
        mem[124] = 18'h06113;
        mem[125] = 18'h0BCF4;
        mem[126] = 18'h000BE;
        mem[127] = 18'h056F2;
        mem[128] = 18'h0BCFA;
        mem[129] = 18'h000BE;
        mem[130] = 18'h04CD2;
        mem[131] = 18'h0BD00;
        mem[132] = 18'h000BE;
        mem[133] = 18'h042B1;
        mem[134] = 18'h0BD06;
        mem[135] = 18'h000BE;
        mem[136] = 18'h03891;
        mem[137] = 18'h0BD0C;
        mem[138] = 18'h000BE;
        mem[139] = 18'h02E70;
        mem[140] = 18'h07912;
        mem[141] = 18'h0017D;
        mem[142] = 18'h00002;
        mem[143] = 18'h0BC00;
        mem[144] = 18'h000BE;
        mem[145] = 18'h0F5E2;
        mem[146] = 18'h0BC05;
        mem[147] = 18'h000BE;
        mem[148] = 18'h0EBC3;
        mem[149] = 18'h0BC0B;
        mem[150] = 18'h000BE;
        mem[151] = 18'h0E1A4;
        mem[152] = 18'h0BC11;
        mem[153] = 18'h000BE;
        mem[154] = 18'h0D784;
        mem[155] = 18'h0BC17;
        mem[156] = 18'h000BE;
        mem[157] = 18'h0CD63;
        mem[158] = 18'h0BC1D;
        mem[159] = 18'h000BE;
        mem[160] = 18'h0C342;
        mem[161] = 18'h0BC23;
        mem[162] = 18'h000BE;
        mem[163] = 18'h0B921;
        mem[164] = 18'h0BE29;
        mem[165] = 18'h000BE;
        mem[166] = 18'h0AF10;
        mem[167] = 18'h0BC2F;
        mem[168] = 18'h000BE;
        mem[169] = 18'h0A4F0;
        mem[170] = 18'h0BC35;
        mem[171] = 18'h000BE;
        mem[172] = 18'h09AD1;
        mem[173] = 18'h0BC3B;
        mem[174] = 18'h000BE;
        mem[175] = 18'h090B2;
        mem[176] = 18'h0BC41;
        mem[177] = 18'h000BE;
        mem[178] = 18'h08692;
        mem[179] = 18'h01A47;
        mem[180] = 18'h0011E;
        mem[181] = 18'h07761;
        mem[182] = 18'h05E50;
        mem[183] = 18'h0005F;
        mem[184] = 18'h07251;
        mem[185] = 18'h07853;
        mem[186] = 18'h0017D;
        mem[187] = 18'h05E12;
        mem[188] = 18'h0BC5F;
        mem[189] = 18'h000BE;
        mem[190] = 18'h053F2;
        mem[191] = 18'h0BC65;
        mem[192] = 18'h000BE;
        mem[193] = 18'h049D3;
        mem[194] = 18'h0BC6B;
        mem[195] = 18'h000BE;
        mem[196] = 18'h03FB4;
        mem[197] = 18'h0BC71;
        mem[198] = 18'h000BE;
        mem[199] = 18'h03594;
        mem[200] = 18'h0BC77;
        mem[201] = 18'h000BE;
        mem[202] = 18'h02B73;
        mem[203] = 18'h0BC7D;
        mem[204] = 18'h000BE;
        mem[205] = 18'h02152;
        mem[206] = 18'h0BC83;
        mem[207] = 18'h000BE;
        mem[208] = 18'h01731;
        mem[209] = 18'h0BE89;
        mem[210] = 18'h000BE;
        mem[211] = 18'h00D20;
        mem[212] = 18'h0BC8F;
        mem[213] = 18'h000BE;
        mem[214] = 18'h00300;
        mem[215] = 18'h0BC95;
        mem[216] = 18'h000BE;
        mem[217] = 18'h0F8E1;
        mem[218] = 18'h0BC9A;
        mem[219] = 18'h000BE;
        mem[220] = 18'h0EEC2;
        mem[221] = 18'h0BCA0;
        mem[222] = 18'h000BE;
        mem[223] = 18'h0E4A1;
        mem[224] = 18'h01AA6;
        mem[225] = 18'h0011E;
        mem[226] = 18'h0D570;
        mem[227] = 18'h05EAF;
        mem[228] = 18'h0005F;
        mem[229] = 18'h0D060;
        mem[230] = 18'h078B2;
        mem[231] = 18'h0017D;
        mem[232] = 18'h00004;
        mem[233] = 18'h0BC00;
        mem[234] = 18'h000BE;
        mem[235] = 18'h0F5E2;
        mem[236] = 18'h0BC05;
        mem[237] = 18'h000BE;
        mem[238] = 18'h0EBC4;
        mem[239] = 18'h0BC0B;
        mem[240] = 18'h000BE;
        mem[241] = 18'h0E1A7;
        mem[242] = 18'h0BC11;
        mem[243] = 18'h000BE;
        mem[244] = 18'h0D785;
        mem[245] = 18'h0BC17;
        mem[246] = 18'h000BE;
        mem[247] = 18'h0CD67;
        mem[248] = 18'h0BC1D;
        mem[249] = 18'h000BE;
        mem[250] = 18'h0C344;
        mem[251] = 18'h07A23;
        mem[252] = 18'h0017D;
        mem[253] = 18'h0AF14;
        mem[254] = 18'h0BC2F;
        mem[255] = 18'h000BE;
        mem[256] = 18'h0A4F7;
        mem[257] = 18'h0BC35;
        mem[258] = 18'h000BE;
        mem[259] = 18'h09AD8;
        mem[260] = 18'h0BC3B;
        mem[261] = 18'h000BE;
        mem[262] = 18'h090B9;
        mem[263] = 18'h0BC41;
        mem[264] = 18'h000BE;
        mem[265] = 18'h08698;
        mem[266] = 18'h07847;
        mem[267] = 18'h0017D;
        mem[268] = 18'h07257;
        mem[269] = 18'h07853;
        mem[270] = 18'h0017D;
        mem[271] = 18'h05E15;
        mem[272] = 18'h0BC5F;
        mem[273] = 18'h000BE;
        mem[274] = 18'h053F7;
        mem[275] = 18'h0BC65;
        mem[276] = 18'h000BE;
        mem[277] = 18'h049D4;
        mem[278] = 18'h0786B;
        mem[279] = 18'h0017D;
        mem[280] = 18'h03594;
        mem[281] = 18'h0BC77;
        mem[282] = 18'h000BE;
        mem[283] = 18'h02B71;
        mem[284] = 18'h0BC7D;
        mem[285] = 18'h000BE;
        mem[286] = 18'h02152;
        mem[287] = 18'h0BC83;
        mem[288] = 18'h000BE;
        mem[289] = 18'h01733;
        mem[290] = 18'h0BE89;
        mem[291] = 18'h000BE;
        mem[292] = 18'h00D26;
        mem[293] = 18'h0BC8F;
        mem[294] = 18'h000BE;
        mem[295] = 18'h00301;
        mem[296] = 18'h0BC95;
        mem[297] = 18'h000BE;
        mem[298] = 18'h0F8E0;
        mem[299] = 18'h0789A;
        mem[300] = 18'h0017D;
        mem[301] = 18'h0E4A0;
        mem[302] = 18'h0FEA6;
        mem[303] = 18'h001FF;
    end

    reg [17:0] rd_data_r;
    reg        rd_valid_r;

    // Only the read-valid control is reset; the memory contents are constants.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_data_r  <= 18'd0;
            rd_valid_r <= 1'b0;
        end else begin
            rd_valid_r <= guide_rom_rd_en;
            if (guide_rom_rd_en)
                rd_data_r <= mem[guide_rom_rd_addr];
        end
    end

    // [17:16] are pad bits and are always zero on the port as well.
    assign guide_rom_rd_data  = {2'b00, rd_data_r[15:0]};
    assign guide_rom_rd_valid = rd_valid_r;

endmodule

`default_nettype wire
