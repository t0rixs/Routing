import React, { useCallback } from 'react';
import { useStore } from './store/useStore';
import GoogleMapComponent from './components/Map/GoogleMap';
import { loadMappingFile } from './lib/mapping/FileLoader';
import { exportMappingFile } from './lib/mapping/FileExporter';
import { Upload, Download, Undo, Redo, Info } from 'lucide-react';
import { saveAs } from 'file-saver';

function App() {
  const { data, setData, setLoading, isLoading, undo, redo, historyIndex, history } = useStore();

  const handleFileUpload = useCallback(async (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    if (!file) return;

    setLoading(true);
    try {
      const loadedData = await loadMappingFile(file);
      setData(loadedData);
    } catch (error) {
      console.error('Failed to load file:', error);
      alert('Failed to load .mapping file');
    } finally {
      setLoading(false);
    }
  }, [setData, setLoading]);

  const handleExport = useCallback(async () => {
    if (!data) return;
    setLoading(true);
    try {
      const blob = await exportMappingFile(data);
      saveAs(blob, data.fileName || 'edited.mapping');
    } catch (error) {
      console.error('Failed to export:', error);
      alert('Failed to export file');
    } finally {
      setLoading(false);
    }
  }, [data, setLoading]);

  const canUndo = historyIndex > 0;
  const canRedo = historyIndex < history.length;

  return (
    <div className="flex flex-col h-screen w-full bg-gray-900 text-white">
      {/* Header */}
      <header className="flex items-center justify-between p-4 bg-gray-800 border-b border-gray-700 shadow-md z-10">
        <div className="flex items-center gap-4">
          <h1 className="text-xl font-bold text-blue-400">Mapping! Web Editor</h1>
          <button
            className="text-gray-400 hover:text-white"
            onClick={() => alert("Mapping! Web Editor MVP\n\nCompatible with Mapping! app.\nData is processed entirely in your browser.\n\nFeedback via email.")}
          >
            <Info size={20} />
          </button>
        </div>

        <div className="flex items-center gap-4">
          {/* Editor Toolbar */}
          <div className="flex items-center gap-2 mr-4 border-r border-gray-600 pr-4">
            <button
              onClick={undo}
              disabled={!canUndo}
              className={`p-2 rounded ${canUndo ? 'hover:bg-gray-700 text-white' : 'text-gray-600 cursor-not-allowed'}`}
              title="Undo"
            >
              <Undo size={20} />
            </button>
            <button
              onClick={redo}
              disabled={!canRedo}
              className={`p-2 rounded ${canRedo ? 'hover:bg-gray-700 text-white' : 'text-gray-600 cursor-not-allowed'}`}
              title="Redo"
            >
              <Redo size={20} />
            </button>
          </div>

          {data && <span className="text-sm text-gray-400 hidden sm:inline truncate max-w-[150px]">{data.fileName}</span>}

          <label className="flex items-center gap-2 px-3 py-2 bg-gray-700 hover:bg-gray-600 rounded cursor-pointer transition-colors text-sm">
            <Upload size={16} />
            <span>Ofen</span>
            <input type="file" accept=".mapping,.zip" onChange={handleFileUpload} className="hidden" />
          </label>

          <button
            onClick={handleExport}
            disabled={!data}
            className={`flex items-center gap-2 px-3 py-2 rounded transition-colors text-sm ${data ? 'bg-blue-600 hover:bg-blue-700 text-white' : 'bg-gray-700 text-gray-500 cursor-not-allowed'}`}
          >
            <Download size={16} />
            <span>Export</span>
          </button>
        </div>
      </header>

      {/* Main Content */}
      <div className="flex-1 relative">
        <GoogleMapComponent />

        {/* Loading Overlay */}
        {isLoading && (
          <div className="absolute inset-0 bg-black/50 z-[1000] flex items-center justify-center">
            <div className="bg-gray-800 p-6 rounded shadow-lg flex flex-col items-center">
              <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-white mb-4"></div>
              <div className="text-white text-lg font-semibold">Processing...</div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

export default App;
