import { Component, computed, DestroyRef, inject, OnInit, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { ApiService } from '../../../../services/api-service';
import { ActivatedRoute } from '@angular/router';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { MatListModule } from '@angular/material/list';
import { MatInputModule } from '@angular/material/input';
import { MatFormFieldModule } from '@angular/material/form-field';
import { TranslateModule } from '@ngx-translate/core';

interface FileEntry {
  name: string;
  isDirectory: boolean;
  size: number;
  lastModified: number;
}

@Component({
  selector: 'app-instance-files',
  standalone: true,
  imports: [
    CommonModule,
    FormsModule,
    MatIconModule,
    MatButtonModule,
    MatListModule,
    MatInputModule,
    MatFormFieldModule,
    TranslateModule
  ],
  templateUrl: './files.component.html',
  styleUrl: './files.component.scss'
})
export class FilesComponent implements OnInit {
  private api = inject(ApiService);
  private route = inject(ActivatedRoute);
  private destroyRef = inject(DestroyRef);

  instanceId = signal<string | null>(null);
  currentPath = signal<string>('');
  files = signal<FileEntry[]>([]);
  isLoading = signal<boolean>(false);
  
  // Editor state
  editingFile = signal<string | null>(null);
  fileContent = signal<string>('');
  isSaving = signal<boolean>(false);

  ngOnInit() {
    this.route.parent?.paramMap
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe(params => {
        const id = params.get('id');
        if (id) {
          this.instanceId.set(id);
          this.loadFiles('');
        }
      });
  }

  loadFiles(path: string) {
    const id = this.instanceId();
    if (!id) return;

    this.isLoading.set(true);
    this.api.listFiles(id, path).subscribe({
      next: (files) => {
        this.files.set(files);
        this.currentPath.set(path);
        this.isLoading.set(false);
      },
      error: () => {
        this.isLoading.set(false);
        // Handle error
      }
    });
  }

  navigateUp() {
    const path = this.currentPath();
    if (!path) return;
    
    const parts = path.split('/');
    parts.pop();
    const newPath = parts.join('/');
    this.loadFiles(newPath);
  }

  openItem(entry: FileEntry) {
    if (entry.isDirectory) {
      const newPath = this.currentPath() ? `${this.currentPath()}/${entry.name}` : entry.name;
      this.loadFiles(newPath);
    } else {
      this.openEditor(entry.name);
    }
  }

  openEditor(fileName: string) {
    const id = this.instanceId();
    if (!id) return;

    const fullPath = this.currentPath() ? `${this.currentPath()}/${fileName}` : fileName;
    this.isLoading.set(true);
    
    this.api.getFileContentText(id, fullPath).subscribe({
      next: (content) => {
        this.fileContent.set(content);
        this.editingFile.set(fullPath);
        this.isLoading.set(false);
      },
      error: () => {
        this.isLoading.set(false);
        alert('Failed to load file');
      }
    });
  }

  saveFile() {
    const id = this.instanceId();
    const path = this.editingFile();
    if (!id || !path) return;

    this.isSaving.set(true);
    this.api.saveFileContent(id, path, this.fileContent()).subscribe({
      next: () => {
        this.isSaving.set(false);
        this.closeEditor();
      },
      error: () => {
        this.isSaving.set(false);
        alert('Failed to save');
      }
    });
  }

  closeEditor() {
    this.editingFile.set(null);
    this.fileContent.set('');
  }

  deleteItem(entry: FileEntry, event: Event) {
    event.stopPropagation();
    if (!confirm(`Delete ${entry.name}?`)) return;

    const id = this.instanceId();
    if (!id) return;
    
    const fullPath = this.currentPath() ? `${this.currentPath()}/${entry.name}` : entry.name;
    
    this.api.deleteFile(id, fullPath).subscribe({
      next: () => this.loadFiles(this.currentPath()),
      error: () => alert('Failed to delete')
    });
  }
}
