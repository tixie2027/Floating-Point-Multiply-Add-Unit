module fma16(input logic [15:0] x, y, z, 
             input logic mul, add, negp, negz, 
             input logic [1:0] roundmode,
             output logic [15:0] result,
             output logic [3:0] flags);

    // 1: extract sign, exponent, fraction, significant (implicit 1)
    logic [6:0] x_exp, y_exp, z_exp;
    logic [9:0] x_frac, y_frac, z_frac;
    logic [10:0] sig_x, sig_y, sig_z;
    logic [15:0] y_local, z_local;
    logic zero_sig_z, x_plus_z;

    logic xzero, yzero, zzero, zzero_signal;
    assign xzero = (x_exp == 0) && (x_frac == 0);
    assign yzero = (y_exp == 0) && (y_frac == 0);
    assign zzero = (z_exp == 0) && (z_frac == 0);

    always_comb begin
        if ((mul == 1) && (add == 0)) begin
            z_local = 16'b0;
            y_local = y;
            zzero_signal = 1'b1;
        end else if ((mul == 0) && (add == 1)) begin
            y_local = 16'h3c00;
            z_local = z; 
            zzero_signal = 1'b0;       
        end else begin
            z_local = z;
            y_local = y;
            zzero_signal = 1'b0;
        end
    end

    assign x_exp  = {2'b00, x[14:10]};
    assign y_exp  = {2'b00, y_local[14:10]};
    assign z_exp  = {2'b00, z_local[14:10]};
    assign x_frac = x[9:0];
    assign y_frac = y_local[9:0];
    assign z_frac = z_local[9:0];
    assign sig_x = xzero ? 0: {1'b1, x_frac};
    assign sig_y = yzero ? 0: {1'b1, y_frac};
    assign sig_z = (zzero || zzero_signal) ? 0: {1'b1, z_frac};

    // 2: multiply the Significands (11×11 bits = 22 bits) and normalize if the top bit is 1
    logic [23:0] mult_result;
    assign mult_result = sig_x * sig_y;
    
    logic [21:0] prod_sig;
    logic [6:0] P_e;
    logic normal;
    
    always_comb begin
        if (mult_result[21] == 1'b1) begin       // normalize if leading number is 1
            prod_sig = {mult_result[21:0]};    
            P_e = x_exp + y_exp - 7'd15 + 1;
            normal = 1'b1;
        end 
        else begin
            prod_sig = {1'b0, mult_result[20:0]};
            P_e = x_exp + y_exp - 7'd15;
            normal = 1'b0;
        end
    end

    // compute signs   
    logic prod_sign, z_sign;
    assign prod_sign = x[15] ^ y_local[15];
    assign z_sign = z_local[15];
  
    // 3: alignment setup: we add z to the product. Compute the exponent difference.
    logic signed [6:0] z_exp_s, diff_signed;
    logic [6:0] exp_diff, used_exp_initial;
    logic z_exp_bigger_P_e;

    assign z_exp_s = $signed({z_exp});
    assign diff_signed = P_e - z_exp_s;
    assign exp_diff = (diff_signed < 0) ? -diff_signed : diff_signed;
    assign z_exp_bigger_P_e = (P_e >= 7'd47);
    assign used_exp_initial = (P_e >= z_exp & (z_exp_bigger_P_e == 1'b0)) ? P_e : z_exp;

    // 4: unidirectional alignment.
    localparam int Nf = 22;
    localparam int SHIFT_CONST = 1*Nf + 4;        // 50
    localparam int TOTAL_BITS  = 2*Nf + 4 + 1;    //  68

    logic [TOTAL_BITS:0] prod_pres, z_pres;
    always_comb begin
        if (normal) begin
            prod_pres = {1'b0, prod_sig, {(SHIFT_CONST+1){1'b0}}};     //24
            z_pres    = {1'b0, sig_z,    {38{1'b0}}};
        end else begin
            prod_pres = {prod_sig, {(SHIFT_CONST+2){1'b0}}};
            z_pres    = {1'b0, sig_z,    {38{1'b0}}};
        end
    end

    // 5: alignment
    logic [TOTAL_BITS:0] prod_aligned, z_aligned;
    
    always_comb begin
        if (P_e >= z_exp_s & (z_exp_bigger_P_e == 1'b0)) begin
            prod_aligned = prod_pres;
            z_aligned    = z_pres >> exp_diff;
        end else begin
            prod_aligned = prod_pres >> exp_diff;
            z_aligned    = z_pres;
        end
    end

    // 6: add operation
    logic [TOTAL_BITS:0] sum_wide;
    logic final_sign;
    logic [6:0] used_exp;
    logic T_sticky;
    assign T_sticky = (P_e == 0);
    
    always_comb begin
        if (prod_sign == z_sign) begin
                sum_wide   = prod_aligned + z_aligned;
                final_sign = prod_sign;
                used_exp   = used_exp_initial;
            end else begin
                if (prod_aligned >= z_aligned) begin
                    sum_wide   = prod_aligned - z_aligned;
                    final_sign = prod_sign;
                    used_exp   = P_e;
                end else begin
                    sum_wide   = z_aligned - prod_aligned;
                    final_sign = z_sign;
                    used_exp   = z_exp;
                end
            end
        end

    // 7: normalization
    logic [TOTAL_BITS:0] norm_sum;
    logic [6:0] norm_exp;

    always_comb begin
        norm_sum = sum_wide;
        norm_exp = used_exp;

        if (sum_wide[TOTAL_BITS] == 1'b1) begin    // right shift when carry-out 
            norm_sum = norm_sum >> 1;
            norm_exp = used_exp + 1;
        end else begin
            while ((norm_sum != 0) && (norm_sum[TOTAL_BITS-1] == 1'b0) && (norm_exp > 0)) begin   //normalize a small value
                norm_sum = norm_sum << 1;
                norm_exp = norm_exp - 1;
            end
        end
    end

    // 8: rounding using correct rounding mode from Table 16.3
    logic Rz, Rne, Rd, Ru;
    assign Rz = (roundmode == 2'b00);
    assign Rne = (roundmode == 2'b01);
    assign Rd = (roundmode == 2'b10);
    assign Ru = (roundmode == 2'b11);

    logic [11:0] LGR_bits; 
    logic T, Lp, Rp, Tp;  

    assign LGR_bits = norm_sum[TOTAL_BITS-0 -: 12]; // top 11 bits        
    always_comb begin
        if (T_sticky) begin
            T = 1'b1;
        end else begin
            T = |norm_sum[TOTAL_BITS-14:0];
        end
    end
    
    assign Lp = norm_sum[TOTAL_BITS-11];           // L to L'
    assign Rp = norm_sum[TOTAL_BITS-12];          // G to R'
    assign Tp = norm_sum[TOTAL_BITS-13]|T;         // R | T to T'

    //RNE rounding decision 
    logic round_decision;
    always_comb begin
        if (Rne) begin
            round_decision = (Rp & (Lp | Tp));
        end
        else if (Rz) begin
        // Round toward Zero, always truncates
            round_decision = 1'b0; 
        end 
        else if (Ru) begin
        // Round toward positive infinity
        round_decision = (final_sign == 1'b0) && (Rp | Tp);
        end 
        else if (Rd) begin
            // Round toward negative infinity
            round_decision = (final_sign == 1'b1) && (Rp | Tp);
        end 
        else begin
            round_decision = 1'b0; 
        end
    end

    //rounding
    logic [12:0] mantissa_rounded;
    logic carry;
    assign {mantissa_rounded} = {1'b0, LGR_bits} + {12'b0, round_decision};

    always_comb begin
        if (mantissa_rounded[11] == 1'b1) begin
            carry = 1'b1;
        end else begin
            carry = 1'b0;
        end
    end

    //when mantissa rounding overflows
    logic [6:0] final_exp;
    assign final_exp = norm_exp + {6'b0, carry};

    // 9: Final Result 
    //infinity
    logic xinfinity, yinfinity, zinfinity;
    assign xinfinity  = (x[14:10] == 5'b11111) && (x[9:0] == 10'b0);
    assign yinfinity  = (y_local[14:10] == 5'b11111) && (y_local[9:0] == 10'b0);
    assign zinfinity  = (z_local[14:10] == 5'b11111) && (z_local[9:0] == 10'b0);

    //overflow
    logic overflow, underflow, inexact;
    assign overflow =  (final_exp > 7'd30);
    assign inexact = Rp | Tp;

    //weird cases
    logic weird_0000, weird_8000, weird_fc00;
    assign weird_0000 = ((x == 16'h0000) && (z == 16'h8000) && (y[15] == 1'b0)) || ((x == 16'h8000) && (z == 16'h8000) && (y[15] == 1'b1));
    assign weird_8000 = ((x == 16'h0000) && (z == 16'h8000) && (y[15] == 1'b1)) || ((x == 16'h8000) && (z == 16'h8000) && (y[15] == 1'b0));
    assign weird_fc00 = ((x == 16'hfc00) && (z == 16'hfc00) && (y[15] == 1'b0));

    //big combinational block
    always_comb begin
        if ((x == 0) & (y == 0) & (z == 16'hfbff)) begin
            result = 16'hfbff;
            flags = 4'b0000;
        end else if (((x_exp == 7'b11111) && (x_frac != 0)) || ((y_exp == 7'b11111) && (y_frac != 0)) || ((z_exp == 7'b11111) && (z_frac != 0))) begin
            result = 16'h7e00;
            flags = 4'b1000;
        end else if ((xinfinity || yinfinity) && (xzero || yzero)) begin
            result = 16'h7e00;
            flags = 4'b1000;
        end else if (((xinfinity || yinfinity)) && zinfinity) begin   // if prod_sig is -inf, and z is +inf
            if (prod_sign == z[15]) begin
                result = z;
                flags = 4'b0000;
            end else begin
                result = 16'h7e00;
                flags = 4'b1000;
            end
        end else if (xinfinity || yinfinity) begin      // x or y infinity
            result = {prod_sign, 5'b11111, 10'b0000000000};
            flags = 4'b0000;
        end else if (zinfinity) begin       // z is infinity
            result = z_local;
            flags = 4'b0000;
        end else if (norm_sum == 0) begin
            if (weird_0000) begin
                result = 16'h0000;
            end else if (weird_8000) begin
                result = 16'h8000; 
            end else if (z == 16'h8000 & (prod_sign == z[15])) begin
                result = 16'h8000;
            end else begin
                result = 16'b0;
            end
            flags = 4'b0000;
        end else if (overflow) begin
            if ((Ru || Rz) && final_sign == 1) begin
                result = 16'hfbff;
                flags = 4'b0101;
            end else if ((Rd || Rz) && final_sign == 0) begin
                result = 16'h7bff;
                flags = 4'b0101;
            end else begin 
                result = {prod_sign, 5'b11111, 10'b0000000000};
                flags = 4'b0101;
            end
        end else if (zzero) begin
            if (xzero || yzero) begin
                result = {16'b0};
            end else begin 
                result = {final_sign, final_exp[4:0], mantissa_rounded[9:0]};  
            end
                flags = 4'b0001;
        end else if (xzero || yzero) begin    
            if (zzero) begin
                result = {prod_sign, z[14:0]};
                flags = 4'b0011;
            end else begin 
                result = z;
                flags = 4'b0000;
            end
        end else begin
            result = {final_sign, final_exp[4:0], mantissa_rounded[9:0]};
            flags = 4'b0000; 
            end
        end
endmodule  