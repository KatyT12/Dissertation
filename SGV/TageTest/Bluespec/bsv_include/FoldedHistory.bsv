import GlobalBranchHistory::*;
import BranchParams::*;
import Vector::*;
import ConfigReg::*; // Need to use this because of run rule reading the history
import Ehr::*;


// Assuming out of order updates, would actually be simpler with in order updates as I could keep a pointer
/*
Alternatively - why not simply recompute the global brnach history which will be easier since we will just shift and load
back in old values, then we can do a full recomputation of the folded history, however it may increase the cycle time

Also need to think about folding historu size, what if less than th

Periodically shift for recovery?

Multiple recovery updates to history? hopefully not possible but may need EHRs


*/

interface FoldedHistory#(numeric type length);
    method Bit#(length) history;
    method Bit#(length) recoveredHistory;
    method Action updateHistory(GlobalBranchHistory#(GlobalHistoryLength) global, Bit#(1) newHistory);
    method Action updateRecoveredHistory(GlobalBranchHistory#(GlobalHistoryLength) global, Bit#(1) taken);
    interface Vector#(MaxSpecSize, RecoverMechanism#(length)) recoverFrom;
    `ifdef DEBUG
    method Action debugInitialise(Bit#(length) newHistory);
    `endif
endinterface


module mkFoldedHistory#(Integer histLength)(FoldedHistory#(length));
    Ehr#(2, Bit#(length)) folded_history <- mkEhr(0);
    
    // For out of order recovery of branch history
    Reg#(Bit#(MaxSpecSize)) last_spec_outcomes <- mkReg(0);
    Reg#(Bit#(MaxSpecSize)) last_removed_history <- mkReg(0);

    PulseWire recover <- mkPulseWire;

    RWire#(Tuple2#(Bit#(1), Bit#(1))) historyRecoveredUpdateData <- mkRWire;
    RWire#(Tuple2#(Bit#(1), Bit#(1))) historyUpdateData <- mkRWire;

    Vector#(MaxSpecSize, RecoverMechanism#(length)) recoverIfc;

    function Action updateWith(Bit#(1) eliminateBit, Bit#(1) newHistory);
        action
            let folded = folded_history[1];
            Bit#(1) new_bit = newHistory ^ folded[valueOf(length)-1];
            Bit#(length) new_folded_history = truncateLSB({folded, new_bit} << 1);

            // Eliminate history out of bounds
            Integer i = histLength % valueOf(length);
            new_folded_history[i] = new_folded_history[i] ^ eliminateBit;
            
            folded_history[1] <= new_folded_history;

            // For recovery updates
            last_spec_outcomes <= truncateLSB({last_spec_outcomes, newHistory} << 1);
            last_removed_history <= truncateLSB({last_removed_history, eliminateBit} << 1);
        endaction
    endfunction

    // Normal update
    (* no_implicit_conditions, fire_when_enabled *)
    rule updateHist(!recover &&& historyUpdateData.wget matches tagged Valid {.eliminateBit, .newHistory});
        updateWith(eliminateBit, newHistory);
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule updateHistRecovered(recover &&& historyRecoveredUpdateData.wget matches tagged Valid {.eliminateBit, .newHistory});
        updateWith(eliminateBit, newHistory);
    endrule

    // Recovery
    function ActionValue#(Bit#(length)) undoHistory(Bit#(TLog#(MaxSpecSize)) i);
        actionvalue
            recover.send;
            UInt#(TLog#(MaxSpecSize)) recoverIndex = unpack(i); 
            // Restore deleted historu
            Bit#(length) recovered = folded_history[0];
            Integer j = histLength % valueOf(length);
            for(Integer k = 0; k < valueOf(MaxSpecSize); k = k +1) begin                    
                if(fromInteger(k) <= i) begin
                    Bit#(1) eliminateBit = last_removed_history[k];
                    Integer position = (j + k) % valueOf(length);
                    recovered[position] = eliminateBit^recovered[position];
                end
            end
            
            Bit#(length) removed = recovered[recoverIndex:0] ^ last_spec_outcomes[recoverIndex:0];
            recovered = (removed[recoverIndex:0] << (valueOf(length)-1)) >> i | truncateLSB(recovered >> (i+1));
            folded_history[0] <= recovered;
            return recovered;
        endactionvalue
    endfunction

    for(Integer i = 0; i < valueOf(MaxSpecSize); i = i+1) begin
        recoverIfc[i] = (interface RecoverMechanism#(length);
            method Action undo;
                let a <- undoHistory(fromInteger(i));
            endmethod

            `ifdef DEBUG
            method ActionValue#(Bit#(length)) debugUndo;
                let ret <- undoHistory(fromInteger(i));
                return ret;
            endmethod
            `endif
        endinterface);
    end

    interface recoverFrom = recoverIfc;

    method Bit#(length) history = folded_history[0];

    method Bit#(length) recoveredHistory = folded_history[1];

    // How to know the pointer? Realistically commit stage cannot know
    // If in order then fetch stage will know which branch because we can keep a pointer
    // But that also requires sending back correct updates to the global history

    method Action updateHistory(GlobalBranchHistory#(GlobalHistoryLength) global, Bit#(1) newHistory);
        // Shift and add new history bit, with older history
        Integer i = histLength % valueOf(length);
        Bit#(1) eliminateBit = global.history[histLength-1];
        historyUpdateData.wset(tuple2(eliminateBit, newHistory));
    endmethod

    method Action updateRecoveredHistory(GlobalBranchHistory#(GlobalHistoryLength) global, Bit#(1) taken);
        Integer i = histLength % valueOf(length);
        Bit#(1) eliminateBit = global.recoveredHistory[histLength-1];
        historyRecoveredUpdateData.wset(tuple2(eliminateBit, taken));
    endmethod

    `ifdef DEBUG
    method Action debugInitialise(Bit#(length) newHistory);
        folded_history[0] <= newHistory;
    endmethod
    `endif
endmodule
//if(lat[j].wget matches tagged Valid .x)