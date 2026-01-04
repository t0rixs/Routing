import JSZip from 'jszip';
import { createDatabaseFromBuffer } from '../db/DBLoader';
import { type MappingContextData, type TileDB } from '../../types';

const XOR_KEY = 0x55;

const xorBuffer = (buffer: ArrayBuffer): ArrayBuffer => {
    const source = new Uint8Array(buffer);
    const result = new Uint8Array(source.length);
    for (let i = 0; i < source.length; i++) {
        result[i] = source[i] ^ XOR_KEY;
    }
    return result.buffer;
};

export const loadMappingFile = async (file: File): Promise<MappingContextData> => {
    const zip = new JSZip();
    const loadedZip = await zip.loadAsync(file);

    const databases = new Map<string, TileDB>();
    const rawFiles = new Map<string, ArrayBuffer>();
    let backupFileName = 'myalltracks.backup'; // Default

    // Process files sequentially to prevent freeze
    const entries: { path: string, entry: JSZip.JSZipObject }[] = [];
    loadedZip.forEach((relativePath, zipEntry) => {
        entries.push({ path: relativePath, entry: zipEntry });
    });

    for (const { path, entry } of entries) {
        if (entry.dir) continue;

        if (path.endsWith('.backup')) {
            backupFileName = path;
            const backupContent = await entry.async('arraybuffer');
            const innerZip = new JSZip();
            const loadedInner = await innerZip.loadAsync(backupContent);

            const innerEntries: { path: string, entry: JSZip.JSZipObject }[] = [];
            loadedInner.forEach((innerPath, innerEntry) => {
                innerEntries.push({ path: innerPath, entry: innerEntry });
            });

            // Process inner DBs sequentially
            for (const { path: innerPath, entry: innerEntry } of innerEntries) {
                if (innerEntry.dir || !innerPath.endsWith('.db')) continue;

                const match = innerPath.match(/^hm_(\d+)_(-?\d+)_(-?\d+)\.db$/);
                if (match) {
                    const encrypted = await innerEntry.async('arraybuffer');
                    const decrypted = xorBuffer(encrypted);
                    const db = await createDatabaseFromBuffer(decrypted);

                    const zoom = parseInt(match[1], 10);
                    const baseLat = parseInt(match[2], 10);
                    const baseLng = parseInt(match[3], 10);
                    const id = `hm_${zoom}_${baseLat}_${baseLng}`;

                    databases.set(id, {
                        id,
                        db,
                        zoom,
                        baseLat,
                        baseLng
                    });
                }
            }
        } else {
            const content = await entry.async('arraybuffer');
            rawFiles.set(path, content);
        }
    }

    return {
        databases,
        rawFiles,
        backupFileName,
        fileName: file.name
    };
};
