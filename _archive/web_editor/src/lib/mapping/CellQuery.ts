import { type Database } from 'sql.js';
import { type Cell } from '../../types';

export const getAllCellsFromDB = (db: Database): Cell[] => {
    try {
        // Check table existence first
        const tables = db.exec("SELECT name FROM sqlite_master WHERE type='table' AND name='heatmap_table'");
        if (tables.length === 0 || tables[0].values.length === 0) {
            return [];
        }

        const res = db.exec("SELECT lat, lng, val, tm, p1 FROM heatmap_table");
        if (res.length === 0) return [];

        const columns = res[0].columns;
        const values = res[0].values;

        const latIdx = columns.indexOf('lat');
        const lngIdx = columns.indexOf('lng');
        const valIdx = columns.indexOf('val');
        const tmIdx = columns.indexOf('tm');
        const p1Idx = columns.indexOf('p1');

        return values.map(row => ({
            lat: row[latIdx] as number,
            lng: row[lngIdx] as number,
            val: row[valIdx] as number,
            tm: row[tmIdx] as number,
            p1: row[p1Idx] as number
        }));
    } catch (e) {
        console.error('Error querying DB:', e);
        return [];
    }
};
