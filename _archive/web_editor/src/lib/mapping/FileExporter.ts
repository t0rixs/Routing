import JSZip from 'jszip';
import { type MappingContextData } from '../../types';

const XOR_KEY = 0x55;

const xorBuffer = (buffer: Uint8Array): Uint8Array => {
    const result = new Uint8Array(buffer.length);
    for (let i = 0; i < buffer.length; i++) {
        result[i] = buffer[i] ^ XOR_KEY;
    }
    return result;
};

export const exportMappingFile = async (data: MappingContextData): Promise<Blob> => {
    const outerZip = new JSZip();
    const backupZip = new JSZip();

    // 1. Process Databases -> Backup Zip
    data.databases.forEach((tileDB) => {
        // Export DB to Uint8Array
        const dbBuffer = tileDB.db.export();

        // Encrypt
        const encrypted = xorBuffer(dbBuffer);

        // Reconstruct filename: .sqlite internal -> .db external
        // id was hm_{zoom}_{lat}_{lng}
        const filename = `${tileDB.id}.db`;
        backupZip.file(filename, encrypted);
    });

    // Generate backup zip buffer
    const backupContent = await backupZip.generateAsync({ type: 'uint8array' });

    // 2. Add backup to outer zip
    // Use stored backupFileName or default
    // Ensure we handle paths correctly if backupFileName includes directories
    outerZip.file(data.backupFileName || 'myalltracks.backup', backupContent);

    // 3. Add raw files (images, etc.)
    data.rawFiles.forEach((buffer, filename) => {
        outerZip.file(filename, buffer);
    });

    // Generate final .mapping zip file
    const blob = await outerZip.generateAsync({ type: 'blob' });
    return blob;
};
