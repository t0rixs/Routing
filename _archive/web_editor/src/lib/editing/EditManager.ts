import { type Database } from 'sql.js';
import { type MappingContextData, type Cell, type TileDB } from '../../types';
import { cellToLatLng, latLngToCell } from '../math/coords';

export interface CellChange {
    zoom: number;
    lat: number;
    lng: number;
    delta: number;
}

// Find the correct DB for a specific zoom/lat/lng
const findDB = (data: MappingContextData, zoom: number, lat: number, lng: number): TileDB | undefined => {
    const baseLat = Math.floor(lat / 1000); // Shard id
    const baseLng = Math.floor(lng / 1000);
    const id = `hm_${zoom}_${baseLat}_${baseLng}`;
    return data.databases.get(id);
};

// Execute modification on DB
const modifyDB = (db: Database, lat: number, lng: number, delta: number) => {
    // Check if exists
    const res = db.exec("SELECT val FROM heatmap_table WHERE lat = ? AND lng = ?", [lat, lng]);
    let currentVal = 0;
    if (res.length > 0 && res[0].values.length > 0) {
        currentVal = res[0].values[0][0] as number;
    }

    const newVal = currentVal + delta;

    if (newVal <= 0) {
        db.run("DELETE FROM heatmap_table WHERE lat = ? AND lng = ?", [lat, lng]);
    } else {
        // Insert or Update. SQLite INSERT OR REPLACE is useful but we want to preserve other fields? 
        // Wait, simpliest is UPDATE if exists, INSERT if not?
        // But here we only support Deletion (Decrement), so cell must exist theoretically.
        // If we support Undo (Increment), we might need to INSERT.
        if (currentVal === 0) {
            // Insert new
            const tm = Date.now();
            db.run("INSERT INTO heatmap_table (lat, lng, val, tm, p1) VALUES (?, ?, ?, ?, ?)", [lat, lng, newVal, tm, tm]);
        } else {
            db.run("UPDATE heatmap_table SET val = ? WHERE lat = ? AND lng = ?", [newVal, lat, lng]);
        }
    }
};

export const executeDeleteCell = (data: MappingContextData, targetCell: Cell & { zoom: number }): CellChange[] => {
    const changes: CellChange[] = [];
    const decrementAmount = - targetCell.val; // Remove completely

    // 1. Target Cell (Zoom 16)
    const targetDB = findDB(data, targetCell.zoom, targetCell.lat, targetCell.lng);
    if (targetDB) {
        modifyDB(targetDB.db, targetCell.lat, targetCell.lng, decrementAmount);
        changes.push({ zoom: targetCell.zoom, lat: targetCell.lat, lng: targetCell.lng, delta: decrementAmount });
    }

    // 2. Parent Cells (Zoom 15 down to 3)
    const center = cellToLatLng(targetCell, targetCell.zoom);

    for (let z = targetCell.zoom - 1; z >= 3; z--) {
        const parentCell = latLngToCell(center.lat, center.lng, z);
        const db = findDB(data, z, parentCell.lat, parentCell.lng);

        if (db) {
            // Modify
            modifyDB(db.db, parentCell.lat, parentCell.lng, decrementAmount);
            changes.push({ zoom: z, lat: parentCell.lat, lng: parentCell.lng, delta: decrementAmount });
        }
    }

    return changes;
};

export const executeUndo = (data: MappingContextData, changes: CellChange[]) => {
    // Reverse changes
    changes.forEach(change => {
        const db = findDB(data, change.zoom, change.lat, change.lng);
        if (db) {
            modifyDB(db.db, change.lat, change.lng, -change.delta); // Negate delta to undo
        }
    });
};
