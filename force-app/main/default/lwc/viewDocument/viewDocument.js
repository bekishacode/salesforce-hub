import { LightningElement, api, track } from 'lwc';
import getAccountDocuments from '@salesforce/apex/FileController.getAccountDocuments';

export default class ViewDocument extends LightningElement {
    @api recordId;
    @track documents = [];
    @track isLoading = false;
    @track error;
    @track isViewerOpen = false;
    @track currentIndex = 0;
    @track isFullscreen = true; // Changed to true by default

    // Store the bound function reference
    boundHandleKeyPress = null;

    connectedCallback() {
        this.loadDocuments();
        // Bind the function once
        this.boundHandleKeyPress = this.handleKeyPress.bind(this);
    }

    loadDocuments() {
        this.isLoading = true;
        getAccountDocuments({ accountId: this.recordId })
        .then(result => {
            this.documents = this.addFileIcons(result || []);
            this.isLoading = false;
        })
        .catch(error => {
            this.error = error;
            this.isLoading = false;
        });
    }

    addFileIcons(documents) {
        return documents.map(doc => {
            let iconName = 'doctype:unknown';
            
            const typeToIcon = {
                'National ID': 'doctype:image',
                'ID Photograph': 'doctype:image', 
                'Proof of Address': 'doctype:pdf',
                'Income Proof': 'doctype:pdf',
                'Passport': 'doctype:pdf',
                'Driving License': 'doctype:pdf'
            };
            
            iconName = typeToIcon[doc.DocumentType] || 'doctype:unknown';
            
            return {
                ...doc,
                iconName: iconName
            };
        });
    }

    handlePreviewAll() {
        if (this.hasDocuments) {
            this.openViewer();
        }
    }

    openViewer() {
        this.currentIndex = 0;
        this.isViewerOpen = true;
        this.isFullscreen = true; // Always open in fullscreen
        // Add keyboard listener when viewer opens
        document.addEventListener('keydown', this.boundHandleKeyPress);
    }

    closeViewer() {
        this.isViewerOpen = false;
        // Remove keyboard listener when viewer closes
        document.removeEventListener('keydown', this.boundHandleKeyPress);
    }

    handleKeyPress(event) {
        if (!this.isViewerOpen) return;

        console.log('Key pressed:', event.key); // Debug log

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
                this.closeViewer();
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

    nextDocument() {
        if (this.hasNext) {
            this.currentIndex++;
            console.log('Next document, index:', this.currentIndex);
        }
    }

    previousDocument() {
        if (this.hasPrevious) {
            this.currentIndex--;
            console.log('Previous document, index:', this.currentIndex);
        }
    }

    jumpToDocument(event) {
        const index = parseInt(event.currentTarget.dataset.index);
        if (index >= 0 && index < this.documents.length) {
            this.currentIndex = index;
        }
    }

    // New methods for keyboard navigation
    jumpToFirst() {
        if (this.hasDocuments) {
            this.currentIndex = 0;
            console.log('Jumped to first document');
        }
    }

    jumpToLast() {
        if (this.hasDocuments) {
            this.currentIndex = this.documents.length - 1;
            console.log('Jumped to last document');
        }
    }

    toggleFullscreen() {
        this.isFullscreen = !this.isFullscreen;
        console.log('Fullscreen toggled:', this.isFullscreen);
    }

    // Image event handlers
    handleImageLoad(event) {
        console.log('Image loaded successfully');
    }

    handleImageError(event) {
        console.error('Error loading image');
    }

    // Computed property for thumbnail items
    get thumbnailItems() {
        if (!this.hasDocuments) return [];
        
        return this.documents.map((doc, index) => {
            return {
                key: doc.DocumentId,
                doc: doc,
                index: index,
                className: index === this.currentIndex ? 'thumbnail-item thumbnail-active' : 'thumbnail-item',
                displayNumber: index + 1
            };
        });
    }

    get hasDocuments() {
        return Array.isArray(this.documents) && this.documents.length > 0;
    }

    get noDocuments() {
        return !this.hasDocuments;
    }

    get canShowNext() {
        return this.hasDocuments && this.currentIndex < this.documents.length - 1;
    }

    get cannotShowNext() {
        return !this.canShowNext;
    }

    get canShowPrevious() {
        return this.hasDocuments && this.currentIndex > 0;
    }

    get cannotShowPrevious() {
        return !this.canShowPrevious;
    }

    get documentCount() {
        return this.hasDocuments ? this.documents.length : 0;
    }

    get currentDocument() {
        return this.hasDocuments && this.documents[this.currentIndex] ? this.documents[this.currentIndex] : null;
    }

    get hasNext() {
        return this.canShowNext;
    }

    get hasPrevious() {
        return this.canShowPrevious;
    }

    get documentCounter() {
        return this.hasDocuments ? `Document ${this.currentIndex + 1} of ${this.documents.length}` : 'No documents';
    }

    get viewerClass() {
        // Always use fullscreen class when isFullscreen is true
        return this.isFullscreen ? 'slds-modal slds-fade-in-open viewer-fullscreen' : 'slds-modal slds-fade-in-open viewer-normal';
    }

    // New getter for fullscreen button icon
    get fullscreenIcon() {
        return this.isFullscreen ? 'utility:minimize' : 'utility:expand_alt';
    }

    // New getter for fullscreen button title
    get fullscreenTitle() {
        return this.isFullscreen ? 'Exit Fullscreen' : 'Enter Fullscreen';
    }

    get errorMessage() {
        return this.error && this.error.body ? this.error.body.message : 
               this.error ? this.error.message : 'Unknown error occurred';
    }

    // Clean up event listeners when component is destroyed
    disconnectedCallback() {
        document.removeEventListener('keydown', this.boundHandleKeyPress);
    }
}