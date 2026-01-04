import { create } from 'zustand';
import { type MappingContextData, type CellWithZoom } from '../types';
import { executeDeleteCell, executeUndo, type CellChange } from '../lib/editing/EditManager';

interface AppState {
    data: MappingContextData | null;
    isLoading: boolean;
    history: CellChange[][];
    historyIndex: number; // Index of the next command to execute (or current position)

    setData: (data: MappingContextData | null) => void;
    setLoading: (loading: boolean) => void;
    deleteCell: (cell: CellWithZoom) => void;
    undo: () => void;
    redo: () => void;
}

export const useStore = create<AppState>((set, get) => ({
    data: null,
    isLoading: false,
    history: [],
    historyIndex: 0,

    setData: (data) => set({ data, history: [], historyIndex: 0 }),
    setLoading: (loading) => set({ isLoading: loading }),

    deleteCell: (cell) => {
        const { data, history, historyIndex } = get();
        if (!data) return;

        const changes = executeDeleteCell(data, cell);

        // Slice history if we are in the middle
        const newHistory = history.slice(0, historyIndex);
        newHistory.push(changes);

        set({
            history: newHistory,
            historyIndex: newHistory.length,
            data: { ...data } // Trigger re-render by creating new reference 
        });
    },

    undo: () => {
        const { data, history, historyIndex } = get();
        if (!data || historyIndex === 0) return;

        const changesToUndo = history[historyIndex - 1];
        executeUndo(data, changesToUndo);

        set({
            historyIndex: historyIndex - 1,
            data: { ...data }
        });
    },

    redo: () => {
        const { data, history, historyIndex } = get();
        if (!data || historyIndex >= history.length) return;

        const changesToRedo = history[historyIndex];
        // Re-execute changes. Since changes contain deltas (-val), we can just re-apply them?
        // Wait, executeDeleteCell calculates delta based on CURRENT state. 
        // But CellChange struct has 'delta' stored.
        // So we need separate executeRedo? 
        // We can reuse executeUndo with negated delta? Or just modifyDB.

        // Let's implement lightweight redo here by re-using executeUndo logic with reversed logic
        // Actually executeUndo negates delta. So calling it with negated delta works?
        // changesToRedo has negative delta (e.g. -3).
        // modifyDB adds delta.
        // So we just need to call modifyDB(lat, lng, delta).

        // Since executeUndo calls modifyDB(..., -delta), passing (..., -delta) would result in +delta.
        // But we want to re-apply -3.
        // So we need modifyDB(..., -3).
        // executeUndo does -(-3) = +3.
        // So we cannot use executeUndo directly unless we map changes.

        // Better to expose modifyDB or manual loop.
        // Let's import executeUndo and re-implement redo loop similar to it but without negation
        // OR create executeRedo in EditManager.

        // For now, let's assume we implement executeRedo in EditManager later or logic here.
        // Let's cheat:
        // executeUndo(data, changes.map(c => ({...c, delta: -c.delta}))); 
        // This flips delta to positive, then executeUndo flips it back to negative? 
        // executeUndo: modifyDB(..., -d).
        // input: -(-3) = +3. executeUndo -> -3. Correct.

        const invertedChanges = changesToRedo.map(c => ({ ...c, delta: -c.delta }));
        executeUndo(data, invertedChanges);

        set({
            historyIndex: historyIndex + 1,
            data: { ...data }
        });
    }
}));
