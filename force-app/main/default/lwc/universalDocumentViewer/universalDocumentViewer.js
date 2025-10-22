import { LightningElement, api, track } from 'lwc';
import getRecordDocuments from '@salesforce/apex/UniversalDocumentController.getRecordDocuments';

export default class UniversalDocumentViewer extends LightningElement {
    @api recordId;
    @api objectApiName; // Optional: if you want to specify object type
    @track documents = [];
    @track isLoading = false;
    @track error;
    @track isZoomViewOpen = false;
    @track currentIndex = 0;
    @track isFullscreen = false;

    boundHandleKeyPress = null;

    connectedCallback() {
        this.loadDocuments();
        this.boundHandleKeyPress = this.handleKeyPress.bind(this);
    }

    loadDocuments() {
        if (!this.recordId) {
            this.error = 'No record ID provided';
            return;
        }

        this.isLoading = true;
        this.error = undefined;
        
        getRecordDocuments({ recordId: this.recordId })
        .then(result => {
            this.documents = this.addFileIcons(result || []);
            this.isLoading = false;
        })
        .catch(error => {
            this.error = error;
            this.isLoading = false;
            console.error('Error loading documents:', error);
        });
    }

    addFileIcons(documents) {
        return documents.map(doc => {
            let iconName = 'doctype:unknown';
            
            // Generic file type detection based on file extension
            if (doc.FileExtension) {
                const ext = doc.FileExtension.toLowerCase();
                
                // Image files
                if (['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'svg'].includes(ext)) {
                    iconName = 'doctype:image';
                } 
                // PDF files
                else if (ext === 'pdf') {
                    iconName = 'doctype:pdf';
                }
                // Word documents
                else if (['doc', 'docx', 'docm'].includes(ext)) {
                    iconName = 'doctype:word';
                }
                // Excel files
                else if (['xls', 'xlsx', 'xlsm', 'csv'].includes(ext)) {
                    iconName = 'doctype:excel';
                }
                // PowerPoint files
                else if (['ppt', 'pptx', 'pptm'].includes(ext)) {
                    iconName = 'doctype:ppt';
                }
                // Text files
                else if (['txt', 'rtf', 'md'].includes(ext)) {
                    iconName = 'doctype:txt';
                }
                // Archive files
                else if (['zip', 'rar', '7z', 'tar', 'gz'].includes(ext)) {
                    iconName = 'doctype:zip';
                }
                // Audio files
                else if (['mp3', 'wav', 'aac', 'flac', 'ogg'].includes(ext)) {
                    iconName = 'doctype:audio';
                }
                // Video files
                else if (['mp4', 'avi', 'mov', 'wmv', 'flv', 'mkv'].includes(ext)) {
                    iconName = 'doctype:video';
                }
            }
            
            // Fallback to document type if no file extension
            if (iconName === 'doctype:unknown' && doc.DocumentType) {
                const docType = doc.DocumentType.toLowerCase();
                if (docType.includes('image') || docType.includes('photo') || docType.includes('picture')) {
                    iconName = 'doctype:image';
                } else if (docType.includes('pdf') || docType.includes('document')) {
                    iconName = 'doctype:pdf';
                }
            }
            
            return {
                ...doc,
                iconName: iconName
            };
        });
    }

    // Open zoom view when user clicks on a grid item
    openZoomView(event) {
        const index = parseInt(event.currentTarget.dataset.index);
        if (index >= 0 && index < this.documents.length) {
            this.currentIndex = index;
            this.isZoomViewOpen = true;
            this.isFullscreen = false;
            document.addEventListener('keydown', this.boundHandleKeyPress);
        }
    }

    closeZoomView() {
        this.isZoomViewOpen = false;
        document.removeEventListener('keydown', this.boundHandleKeyPress);
    }

    // Navigation methods for zoom view
    nextDocument() {
        if (this.hasNext) {
            this.currentIndex++;
        }
    }

    previousDocument() {
        if (this.hasPrevious) {
            this.currentIndex--;
        }
    }

    jumpToDocument(event) {
        const index = parseInt(event.currentTarget.dataset.index);
        if (index >= 0 && index < this.documents.length) {
            this.currentIndex = index;
        }
    }

    toggleFullscreen() {
        this.isFullscreen = !this.isFullscreen;
    }

    handleKeyPress(event) {
        if (!this.isZoomViewOpen) return;

        switch(event.key) {
            case 'ArrowLeft':
                event.preventDefault();
                this.previousDocument();
                break;
            case 'ArrowRight':
                event.preventDefault();
                this.nextDocument();
                break;
            case 'Escape':
                event.preventDefault();
                this.closeZoomView();
                break;
            case 'Home':
                event.preventDefault();
                this.jumpToFirst();
                break;
            case 'End':
                event.preventDefault();
                this.jumpToLast();
                break;
            case 'f':
            case 'F':
                event.preventDefault();
                this.toggleFullscreen();
                break;
        }
    }

    jumpToFirst() {
        if (this.hasDocuments) {
            this.currentIndex = 0;
        }
    }

    jumpToLast() {
        if (this.hasDocuments) {
            this.currentIndex = this.documents.length - 1;
        }
    }

    handleImageLoad(event) {
        console.log('Image loaded successfully');
    }

    handleImageError(event) {
        console.error('Error loading image');
    }

    // Refresh documents
    refreshDocuments() {
        this.loadDocuments();
    }

    // Computed properties
    get hasDocuments() {
        return Array.isArray(this.documents) && this.documents.length > 0;
    }

    get noDocuments() {
        return !this.hasDocuments;
    }

    get currentDocument() {
        return this.hasDocuments && this.documents[this.currentIndex] ? this.documents[this.currentIndex] : null;
    }

    get hasNext() {
        return this.hasDocuments && this.currentIndex < this.documents.length - 1;
    }

    get hasPrevious() {
        return this.hasDocuments && this.currentIndex > 0;
    }

    get cannotShowPrevious() {
        return !this.hasPrevious;
    }

    get cannotShowNext() {
        return !this.hasNext;
    }

    get documentCounter() {
        return this.hasDocuments ? `Document ${this.currentIndex + 1} of ${this.documents.length}` : 'No documents';
    }

    get zoomViewClass() {
        return this.isFullscreen ? 'slds-modal slds-fade-in-open zoom-view-fullscreen' : 'slds-modal slds-fade-in-open zoom-view-normal';
    }

    get fullscreenIcon() {
        return this.isFullscreen ? 'utility:minimize' : 'utility:expand_alt';
    }

    get fullscreenTitle() {
        return this.isFullscreen ? 'Exit Fullscreen' : 'Enter Fullscreen';
    }

    get errorMessage() {
        return this.error && this.error.body ? this.error.body.message : 
               this.error ? this.error.message : 'Unknown error occurred';
    }

    // Get documents by type for filtering (future enhancement)
    get imageDocuments() {
        return this.documents.filter(doc => doc.isImage);
    }

    get pdfDocuments() {
        return this.documents.filter(doc => doc.isPdf);
    }

    get otherDocuments() {
        return this.documents.filter(doc => !doc.isImage && !doc.isPdf);
    }

    disconnectedCallback() {
        document.removeEventListener('keydown', this.boundHandleKeyPress);
    }

    // Handle record ID changes
    @api
    refresh() {
        this.loadDocuments();
    }
}