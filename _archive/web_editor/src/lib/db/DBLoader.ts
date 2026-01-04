import initSqlJs, { type Database, type SqlJsStatic } from 'sql.js';

let SQL: SqlJsStatic | null = null;

export const initDB = async () => {
    if (SQL) return SQL;
    SQL = await initSqlJs({
        locateFile: file => `/${file}` // Load from public folder
    });
    return SQL;
};

export const createDatabaseFromBuffer = async (buffer: ArrayBuffer): Promise<Database> => {
    const sql = await initDB();
    return new sql.Database(new Uint8Array(buffer));
};

export const createEmptyDatabase = async (): Promise<Database> => {
    const sql = await initDB();
    return new sql.Database();
};
